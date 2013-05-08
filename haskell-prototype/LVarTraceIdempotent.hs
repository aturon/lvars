{-# LANGUAGE RankNTypes #-} 
{-# LANGUAGE CPP #-}
{-# LANGUAGE NamedFieldPuns, BangPatterns #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall -fno-warn-name-shadowing -fno-warn-unused-do-bind #-}

-- | This (experimental) module generalizes the Par monad to allow
-- arbitrary LVars (lattice variables), not just IVars.
-- 
-- This module exposes the internals of the @Par@ monad so that you
-- can build your own scheduler or other extensions.  Do not use this
-- module for purposes other than extending the @Par@ monad with new
-- functionality.

module LVarTraceIdempotent 
  (
    -- * LVar interface (for library writers):
   runParIO, fork, LVar(..), newLV, getLV, putLV, liftIO,
   Par(),
   Trace(..), runCont, consumeLV, newLVWithCallback,
   IVarContents(..), fromIVarContents,
   
   -- * Example use case: Basic IVar ops.
   runPar, IVar(), new, put, put_, get, spawn, spawn_, spawnP,
   
   -- * DEBUGGING only:
   unsafePeekLV
  ) where

import           Control.Monad hiding (sequence, join)
import           Control.Concurrent hiding (yield)
import           Control.DeepSeq
import           Control.Applicative
import           Data.IORef
import qualified Data.Map as M
import qualified Data.Set as S
import           GHC.Conc hiding (yield)
import           System.IO.Unsafe (unsafePerformIO)
import           Prelude  hiding (mapM, sequence, head, tail)

import qualified Control.Monad.Par.Class as PC

import           Common (forkWithExceptions)

import qualified Sched as Sched

------------------------------------------------------------------------------
-- IVars implemented on top of LVars:
------------------------------------------------------------------------------

-- TODO: newtype and hide the constructor:
newtype IVar a = IVar (LVar (IORef (IVarContents a)))

newtype IVarContents a = IVarContents (Maybe a)
fromIVarContents :: IVarContents a -> Maybe a
fromIVarContents (IVarContents x) = x

new :: Par (IVar a)
new = IVar <$> newLV (newIORef (IVarContents Nothing))

-- | read the value in a @IVar@.  The 'get' can only return when the
-- value has been written by a prior or parallel @put@ to the same
-- @IVar@.
get :: IVar a -> Par a
get (IVar lv@(LVar ref _ _)) = getLV lv poll
 where
   poll = fmap fromIVarContents $ readIORef ref

-- | put a value into a @IVar@.  Multiple 'put's to the same @IVar@
-- are not allowed, and result in a runtime error.
put_ :: IVar a -> a -> Par ()
put_ (IVar iv) elt = putLV iv putter
 where
   putter ref =
     atomicModifyIORef ref $ \ x ->
        case fromIVarContents x of
          Nothing -> (IVarContents (Just elt), ())
          Just  _ -> error "multiple puts to an IVar"

spawn :: NFData a => Par a -> Par (IVar a)
spawn p  = do r <- new;  fork (p >>= put r);   return r
              
spawn_ :: Par a -> Par (IVar a)
spawn_ p = do r <- new;  fork (p >>= put_ r);  return r

spawnP :: NFData a => a -> Par (IVar a)
spawnP a = spawn (return a)

put :: NFData a => IVar a -> a -> Par ()
put v a = deepseq a (put_ v a)

instance PC.ParFuture IVar Par where
  spawn_ = spawn_
  get = get

instance PC.ParIVar IVar Par where
  fork = fork  
  put_ = put_
  new = new
  
------------------------------------------------------------------------------
-- Underlying LVar representation:
------------------------------------------------------------------------------

-- | An LVar consists of a piece of mutable state, a list of polling
-- functions that produce continuations when they are successful, and
-- an optional callback, triggered after every write to the LVar, that
-- takes the written value as its argument.
-- 
-- This implementation cannot provide scalable LVars (e.g., a
-- concurrent hashmap); rather, accesses to a single LVar will
-- contend.  But even if operations on an LVar are serialized, they
-- cannot all be a single "atomicModifyIORef", because atomic
-- modifications must be pure functions, whereas the LVar polling
-- functions are in the IO monad.
data LVar a d = LVar {
  lvstate :: a,
  blocked :: {-# UNPACK #-} !(),
  callback :: Maybe (a -> IO Trace)
}

-- A poller can only be removed from the Map when it is woken.
data Poller = Poller {
   poll  :: IO (Maybe Trace),
   woken :: {-# UNPACK #-}! (IORef Bool)
}

------------------------------------------------------------------------------
-- Generic scheduler with LVars:
------------------------------------------------------------------------------

newtype Par a = Par {
    runCont :: (a -> Trace) -> Trace
}

instance Functor Par where
    fmap f m = Par $ \c -> runCont m (c . f)

instance Monad Par where
    return a = Par ($ a)
    m >>= k  = Par $ \c -> runCont m $ \a -> runCont (k a) c

instance Applicative Par where
   (<*>) = ap
   pure  = return

-- | Trying this using only parametric polymorphism:   
data Trace =
  forall a b . Get (LVar a) (IO (Maybe b)) (b -> Trace)
  | forall a . Put (LVar a) (a -> IO ()) Trace
  | forall a . New (IO a) (LVar a -> Trace)
  | Fork Trace Trace
  | Done
  | DoIO (IO ()) Trace
  | Yield Trace
    
  -- Destructively consume the value (limited nondeterminism):
  | forall a b . Consume (LVar a) (a -> IO b) (b -> Trace)
    
  -- For debugging:
  | forall a b . Peek (LVar a) (a -> IO b) (b -> Trace)

-- | The main scheduler loop.
exec :: Sched.Queue Trace -> Trace -> IO ()
exec queue t = loop t
 where
  loop origt = case origt of
    New init cont -> do
      ref <- newIORef$ LVarContents init []
      loop (cont (LVar ref Nothing))

    NewWithCallBack init cb cont -> do
      ref <- newIORef$ LVarContents init []
      loop (cont$ LVar ref (Just cb))

    Get (LVar ref _) thresh cont -> do
      -- Tradeoff: we could do a plain read before the
      -- atomicModifyIORef.  But that would require evaluating the
      -- threshold function TWICE if we need to block.  (Which is
      -- potentially more expensive than in the plain IVar case.)
      -- e <- readIORef ref
      let thisCB x =
--            trace ("... LVar blocked, thresh attempted "++show(hashStableName$ unsafePerformIO$ makeStableName x))
            fmap cont $ thresh x
      r <- atomicModifyIORef ref $ \ st@(LVarContents a ls) ->
        case thresh a of
          Just b  -> -- trace ("... LVar get, thresh passed ")
                     (st, loop (cont b))
          Nothing -> (LVarContents a (thisCB:ls), reschedule queue)
      r

    Consume (LVar ref _) cont -> do
      -- HACK!  We know nothing about the type of state.  But we CAN
      -- destroy it to prevent any future access:
      a <- atomicModifyIORef ref (\(LVarContents a _) ->
                                   (error "attempt to touch LVar after Consume operation!", a))
      loop (cont a)

    Peek (LVar ref _) cont -> do
      LVarContents {current} <- readIORef ref     
      loop (cont current)

    Put (LVar ref cb) new tr  -> do
      cs <- atomicModifyIORef ref $ \e -> case e of
              LVarContents a ls ->
                let new' = join a new
                    (ls',woken) = loop ls [] []
                    loop [] f w = (f,w)
                    loop (hd:tl) f w =
                      case hd new' of
                        Just trc -> loop tl f (trc:w)
                        Nothing  -> loop tl (hd:f) w
                    -- Callbacks invoked: 
                    woken' = case cb of
                              Nothing -> woken
                              Just fn -> fn a new' : woken
                in 
                deepseq new' (LVarContents new' ls', woken')
      mapM_ (pushWork queue) cs
      loop tr              

    Fork child parent -> do
      Sched.pushWork queue parent -- "Work-first" policy.
      loop child
      -- Sched.pushWork queue child -- "Help-first" policy.  Generally bad.
      -- loop parent

    Done -> sched queue

    DoIO io t -> io >> loop t

    Yield parent -> do
      Sched.yieldWork queue parent
      sched queue
  
{-# INLINE sched #-}
sched :: Sched.Queue Trace -> IO ()
sched q = do
  n <- Sched.next q
  case n of
    Just t  -> exec t >> sched q
    Nothing -> return ()

-- Forcing evaluation of a LVar is fruitless.
instance NFData (LVar a) where
  rnf _ = ()
  
{-# INLINE runPar_internal #-}
runPar_internal :: Par a -> IO a
runPar_internal c = do
  queues <- Sched.new numCapabilities  
  
  -- We create a thread on each CPU with forkOn.  The CPU on which
  -- the current thread is running will host the main thread; the
  -- other CPUs will host worker threads.
  main_cpu <- Sched.currentCPU
  m <- newEmptyMVar  
  forM_ (zip [0..] queues) $ \(cpu, s) ->
    forkWithExceptions (forkOn cpu) "worker thread" $ do
      when (cpu == main_cpu) $
        exec s $ runCont (do x' <- x; liftIO (putMVar m x')) (const Done)
      sched s      
  takeMVar m  

runPar :: Par a -> a
runPar = unsafePerformIO . runPar_internal

-- | A version that avoids an internal `unsafePerformIO` for calling
-- contexts that are already in the `IO` monad.
runParIO :: Par a -> IO a
runParIO = runPar_internal

--------------------------------------------------------------------------------
-- Basic stuff:

-- Not in 6.12: {- INLINABLE fork -}
{-# INLINE fork #-}
fork :: Par () -> Par ()
fork p = Par $ \c -> Fork (runCont p (\_ -> Done)) (c ())

--------------------------------------------------------------------------------

-- | Internal operation.  Creates a new @LVar@ with an initial value.
newLV :: IO lv -> Par (LVar lv)
newLV init = Par $ New init

newLVWithCallback :: IO (lv, lv -> IO Trace) -> Par (LVar lv)
newLVWithCallback = Par .  NewWithCallBack

-- | Internal operation.  Test if the LVar satisfies the given
-- threshold.
getLV :: LVar a -> (IO (Maybe b)) -> Par b
getLV lv poll = Par $ Get lv poll

-- | Internal operation.  Modify the LVar.  Had better be monotonic.
putLV :: LVar a -> (a -> IO ()) -> Par ()
putLV lv fn = Par $ \c -> Put lv fn (c ())

-- | Internal operation. Destructively consume the LVar, yielding
-- access to its precise state.
consumeLV :: LVar a -> (a -> IO b) -> Par b
consumeLV lv extractor = Par $ Consume lv extractor

unsafePeekLV :: LVar a -> (a -> IO b) -> Par b
unsafePeekLV lv extractor = Par $ Peek lv extractor

liftIO :: IO () -> Par ()
liftIO io = Par $ \c -> DoIO io (c ())
