module ConcurrentBag where

import qualified Data.Map as M

------------------------------------------------------------------------------
-- A nonscalable implementation of a concurrent bag
------------------------------------------------------------------------------

type UID = Int
type Bag a = IORef (M.Map UID a)

-- Return the old value.  Could replace with a true atomic op.
atomicIncr :: IORef Int -> IO Int
atomicIncr cntr = atomicModifyIORef cntr (\c -> (c+1,c))

uidCntr :: IORef UID
uidCntr = unsafePerformIO (newIORef 0)

getUID :: IO UID
getUID =  atomicIncr uidCntr

add :: Bag a -> a -> IO ()
add b x = do
  uid <- getUID
  atomicallyModifyIORef b $ \m -> (M.insert uid x m, ())
  
-- a terrible representation that requires scanning the entire bag in advance
type Cursor a = (Bag a, IORef [(UID, a)])

getCursor :: Bag a -> IO (Cursor a)
getCursor b = do
  contents <- atomicallyModifyIORef b $ \m -> (m, assocs m)
  listRef <- newIORef contents
  return (b, listRef)

next :: Cursor a -> Bool -> IO (Maybe (a, Cursor a))
next cursor remove = do
  when remove $ do
    atomicallyModifyIORef 