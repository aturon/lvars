module Data.Concurrent.Bag(Bag, put, take, IterAction(..), iter) where

import           Control.Monad hiding (sequence, join)
import           Control.Concurrent hiding (yield)
import           System.IO.Unsafe (unsafePerformIO)
import           Data.IORef
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

new :: IO (Bag a)
new = newIORef (M.empty)

put :: Bag a -> a -> IO ()
put b x = do
  uid <- getUID
  atomicallyModifyIORef b $ \m -> (M.insert uid x m, ())
  
-- | Removes and returns an element of the bag, if one is available.
take :: Bag a -> IO (Maybe a)  
take = error "todo"

data IterAction = Remove | Keep

-- | iter b f will traverse b (concurrently with updates), applying f to each
-- encountered element.
iter :: Bag a -> (a -> IO IterAction) -> IO ()
iter = error "todo"