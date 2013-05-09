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
import qualified Data.Concurrent.Counter as C
import qualified Data.Concurrent.Bag as B
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

-- AJT TODO: add commentary
data LVar a d = LVar {
  state     :: a,
  -- to avoid extra allocation, give callback direct access to the local queue
  callbacks :: B.Bag (Sched.Queue Trace -> d -> IO B.IterAction), 
  frozen    :: IORef Bool
}

type HandlerPool = (C.Counter, B.Bag Trace)

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
  -- Create an LVar
    forall a d . New (IO a)                     -- initial value
                     (LVar a -> Trace)          -- continuation
    
  -- Treshhold reads from an LVar
  | forall a b d . Get (LVar a d)               -- the LVar 
                       (a -> IO (Maybe b))      -- already past threshhold?
                       (d -> IO (Maybe b))      -- does d pass the threshhold?
                       (b -> Trace)             -- continuation
    
  -- Update an LVar
  | forall a d . Put (LVar a d)                 -- the LVar
                     (a -> IO (Maybe d))        -- how to do the put
                     Trace                      -- continuation
    
  -- Destructively consume the value (limited nondeterminism):
  | forall a b . Consume (LVar a)               -- the LVar to consume
                         (a -> IO b)            -- 
                         (b -> Trace)           -- 
  
  -- Handler pools and handlers
  | NewHandlerPool (HandlerPool -> trace)
  | forall a d . AddHandler HandlerPool             -- pool to enroll in
                            (LVar a d)              -- LVar to listen to
                            (a -> IO (Maybe Trace)) -- initial callback
                            (d -> IO (Maybe Trace)) -- subsequent callbaks
                            Trace                   -- continuation
  | Quiesce HandlerPool Trace
  
  | Fork Trace Trace
  | Done
  | HandlerDone HandlerPool
  | DoIO (IO ()) Trace
  | Yield Trace
        
  -- For debugging:
  | forall a b . Peek (LVar a) (a -> IO b) (b -> Trace)

-- | The main scheduler loop.
exec :: Sched.Queue Trace -> Trace -> IO ()
exec queue t = loop t
 where
  loop origt = case origt of
    New init cont -> do
      state <- init
      callbacks <- B.new
      frozen <- newIORef False
      loop (cont (LVar state callbacks frozen))

    Get (LVar state callbacks frozen) poll callback cont -> do
      let thisCB q d = do
        pastThresh <- callback d
        case pastTresh of
          Just b -> do
            Sched.pushWork q (cont b)
            return Remove
          Nothing -> return Keep
          
      -- tradeoff: we fastpath the case where the LVar is already beyond the
      -- threshhold by polling *before* enrolling the callback.  The price is
      -- that, if we are not currently above the threshhold, we will have to
      -- poll *again* after enrolling the callback.  This race may also result
      -- in the continuation being executed twice, which is permitted by
      -- idempotence.
          
      pastThresh <- poll state 
      case pastThresh of 
        Just b -> loop (cont b) 
        Nothing -> do
          B.put callbacks thisCB
          pastThresh' <- poll state -- poll again
          case pastThresh' of
            Just b -> loop (cont b)  -- TODO: remove callback
            Nothing -> sched queue

    Put (LVar state callbacks frozen) doPut cont  -> do
      change <- doPut state
      case change of
        Nothing -> loop cont   -- no change, so nothing to do
        Just d -> do
          isConsumed <- readIORef frozen
          when isConsumed $ error "Attempt to change a consumed LVar"
          B.iter callbacks $ \cb -> cb queue d
      
    Consume (LVar state callbacks frozen) extractor cont -> do
      atomicallyModifyIORef frozen $ \_ -> (true, ())
      contents <- extractor state
      loop (cont contents)
      
    -- Peek (LVar ref _) cont -> do
    --   LVarContents {current} <- readIORef ref     
    --   loop (cont current)      
      
      
  -- | NewHandlerPool (HandlerPool -> trace)
  -- | forall a d . AddHandler HandlerPool             -- pool to enroll in
  --                           (LVar a d)              -- LVar to listen to
  --                           (a -> IO (Maybe Trace)) -- initial callback
  --                           (d -> IO (Maybe Trace)) -- subsequent callbaks
  --                           Trace                   -- continuation
  -- | Quiesce HandlerPool Trace
      
    NewHandlerPool cont -> do
      cnt <- C.new
      cbs <- B.new
      loop (cont (cnt, cbs))
      
    AddHandler (cnt, _) (LVar state callbacks frozen) poll callback cont -> do
      let enroll Nothing  = return ()
          enroll (Just t) = do
            C.inc cnt   -- record thread creation
            pushWork t  -- create callback thread, which is responsible for
                        -- recording its termination in hp
      let thisCB q d = do
            enroll <<= callback d
            return Keep -- for now, always retain callback
            
      B.put callbacks thisCB  -- first, log the callback
      enroll <<= poll a       -- then, poll to see whether we should launch callbacks now
      loop cont
      
    Quiesce (cnt, cbs) cont -> do
      -- todo: optimize this by checking for quiescence first?  
      -- that's probably the less likely case, though.
      B.put cbs cont 
      quiescent <- C.poll cnt
      if quiescent
        then loop cont  -- todo: remove callback from bag?
        else sched queue
          
    DoneHandler (cnt, cbs) -> do      
      C.dec cnt
      quiescent <- C.poll cnt
      when quiescent $ do
        B.iter cbs $ \cb -> do
          Sched.pushWork queue cb
          return Remove
      sched queue

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
