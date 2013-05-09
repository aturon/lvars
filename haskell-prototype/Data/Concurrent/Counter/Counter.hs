module Data.Concurrent.Counter(Counter, new, inc, dec, awaitZero) where

type Counter = IORef Int

new :: IO Counter
new = newIORef 0

inc :: Counter a -> IO ()
inc c = atomicallyModifyIORef c $ \n -> (n+1,())

dec :: Counter a -> IO ()
dec c = atomicallyModifyIORef c $ \n -> (n-1,())

-- | Is the counter (transiently) zero?
poll :: Counter -> IO Bool
poll = error "todo"