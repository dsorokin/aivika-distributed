
{-# LANGUAGE FlexibleContexts #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Dequeue
-- Copyright  : Copyright (c) 2015-2018, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 8.0.1
--
-- An imperative dequeue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Dequeue
       (Dequeue, 
        newDequeue, 
        copyDequeue,
        dequeueCount,
        dequeueNull,
        appendDequeue,
        prependDequeue,
        readDequeue, 
        writeDequeue,
        dequeueBinarySearch,
        dequeueFirst,
        dequeueLast,
        dequeueInsert,
        dequeueDeleteFirst,
        dequeueDeleteLast,
        dequeueDeleteAt,
        freezeDequeue) where 

import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import Data.IORef

import Control.Monad

-- | Represents a resizable dequeue.
data Dequeue a = Dequeue { dequeueArrayRef :: IORef (MV.IOVector a),
                           dequeueCountRef :: IORef Int,
                           dequeueStartRef :: IORef Int,
                           dequeueCapacityRef :: IORef Int }

-- | Create a new dequeue.
newDequeue :: IO (Dequeue a)
newDequeue = 
  do array <- MV.new 4
     arrayRef <- newIORef array
     countRef <- newIORef 0
     startRef <- newIORef 0
     capacityRef <- newIORef 4
     return Dequeue { dequeueArrayRef = arrayRef,
                      dequeueCountRef = countRef,
                      dequeueStartRef = startRef,
                      dequeueCapacityRef = capacityRef }

-- | Copy the dequeue.
copyDequeue :: Dequeue a -> IO (Dequeue a)
copyDequeue dequeue =
  do array <- readIORef (dequeueArrayRef dequeue)
     count <- readIORef (dequeueCountRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     array' <- MV.new count
     arrayRef' <- newIORef array'
     countRef' <- newIORef count
     startRef' <- newIORef 0
     capacityRef' <- newIORef count
     forM_ [0 .. count - 1] $ \i ->
       do x <- MV.read array ((i + start) `mod` capacity)
          MV.write array' i x
     return Dequeue { dequeueArrayRef = arrayRef',
                      dequeueCountRef = countRef',
                      dequeueStartRef = startRef',
                      dequeueCapacityRef = capacityRef' }

-- | Ensure that the dequeue has the specified capacity.
dequeueEnsureCapacity :: Dequeue a -> Int -> IO ()
dequeueEnsureCapacity dequeue capacity =
  do capacity' <- readIORef (dequeueCapacityRef dequeue)
     when (capacity' < capacity) $
       do array' <- readIORef (dequeueArrayRef dequeue)
          count' <- readIORef (dequeueCountRef dequeue)
          start' <- readIORef (dequeueStartRef dequeue)
          let capacity'' = max (2 * capacity') capacity
          array'' <- MV.new capacity''
          forM_ [0 .. count' - 1] $ \i ->
            do x <- MV.read array' ((i + start') `mod` capacity')
               MV.write array'' i x
          writeIORef (dequeueArrayRef dequeue) array''
          writeIORef (dequeueStartRef dequeue) 0
          writeIORef (dequeueCapacityRef dequeue) capacity''
          
-- | Return the element count.
dequeueCount :: Dequeue a -> IO Int
{-# INLINE dequeueCount #-}
dequeueCount dequeue = readIORef (dequeueCountRef dequeue)
          
-- | Return a flag indicating whether the dequeue is empty.
dequeueNull :: Dequeue a -> IO Bool
{-# INLINE dequeueNull #-}
dequeueNull dequeue =
  do count <- readIORef (dequeueCountRef dequeue)
     return (count == 0)
          
-- | Add the specified element to the end of the dequeue.
appendDequeue :: Dequeue a -> a -> IO ()          
appendDequeue dequeue item =
  do count <- readIORef (dequeueCountRef dequeue)
     dequeueEnsureCapacity dequeue (count + 1)
     start <- readIORef (dequeueStartRef dequeue)
     array <- readIORef (dequeueArrayRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     let end    = (start + count) `mod` capacity
         count' = count + 1 
     MV.write array end item
     count' `seq` writeIORef (dequeueCountRef dequeue) count'
          
-- | Add the specified element to the beginning of the dequeue.
prependDequeue :: Dequeue a -> a -> IO ()          
prependDequeue dequeue item =
  do count <- readIORef (dequeueCountRef dequeue)
     dequeueEnsureCapacity dequeue (count + 1)
     start <- readIORef (dequeueStartRef dequeue)
     array <- readIORef (dequeueArrayRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     let start' = (start - 1 + capacity) `mod` capacity
         count' = count + 1
     MV.write array start' item
     count' `seq` writeIORef (dequeueCountRef dequeue) count'
     start' `seq` writeIORef (dequeueStartRef dequeue) start'
     
-- | Read a value from the dequeue, where indices are started from 0.
readDequeue :: Dequeue a -> Int -> IO a
{-# INLINE readDequeue #-}
readDequeue dequeue index =
  do array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     MV.read array ((index + start) `mod` capacity)
          
-- | Set the dequeue item at the specified index which is started from 0.
writeDequeue :: Dequeue a -> Int -> a -> IO ()
{-# INLINE writeDequeue #-}
writeDequeue dequeue index item =
  do array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     MV.write array ((index + start) `mod` capacity) item

dequeueBinarySearch' :: Ord a => Dequeue a -> a -> Int -> Int -> IO Int
dequeueBinarySearch' dequeue item left right =
  if left > right 
  then return $ - (right + 1) - 1
  else
    do let index = (left + right) `div` 2
       curr <- readDequeue dequeue index
       if item < curr 
         then dequeueBinarySearch' dequeue item left (index - 1)
         else if item == curr
              then return index
              else dequeueBinarySearch' dequeue item (index + 1) right
                   
-- | Return the index of the specified element using binary search; otherwise, 
-- a negated insertion index minus one: 0 -> -0 - 1, ..., i -> -i - 1, ....
dequeueBinarySearch :: Ord a => Dequeue a -> a -> IO Int
dequeueBinarySearch dequeue item =
  do count <- readIORef (dequeueCountRef dequeue)
     dequeueBinarySearch' dequeue item 0 (count - 1)

-- | Return the elements of the dequeue in an immutable array.
freezeDequeue :: Dequeue a -> IO (V.Vector a)
freezeDequeue dequeue = 
  do dequeue' <- copyDequeue dequeue
     array    <- readIORef (dequeueArrayRef dequeue')
     V.freeze array
     
-- | Insert the element in the dequeue at the specified index.
dequeueInsert :: Dequeue a -> Int -> a -> IO ()          
dequeueInsert dequeue index item =
  do count <- readIORef (dequeueCountRef dequeue)
     when (index < 0) $
       error $
       "Index cannot be " ++
       "negative: dequeueInsert."
     when (index > count) $
       error $
       "Index cannot be greater " ++
       "than the count: dequeueInsert."
     let count' = count + 1
     dequeueEnsureCapacity dequeue count'
     array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     count <- readIORef (dequeueCountRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     if index >= count `div` 2
       then do forM_ [count, count - 1 .. index + 1] $ \i ->
                 do x <- MV.read array ((start + i - 1) `mod` capacity)
                    MV.write array ((start + i) `mod` capacity) x
               MV.write array ((start + index) `mod` capacity) item
       else do forM_ [-1, 0 .. index - 2] $ \i ->
                 do x <- MV.read array ((start + i + 1) `mod` capacity)
                    MV.write array ((start + i + capacity) `mod` capacity) x
               let start' = (start - 1 + capacity) `mod` capacity
               MV.write array ((start' + index) `mod` capacity) item
               start' `seq` writeIORef (dequeueStartRef dequeue) start'
     count' `seq` writeIORef (dequeueCountRef dequeue) count'
     
-- | Delete the element at the specified index.
dequeueDeleteAt :: Dequeue a -> Int -> IO ()
dequeueDeleteAt dequeue index =
  do count <- readIORef (dequeueCountRef dequeue)
     when (index < 0) $
       error $
       "Index cannot be " ++
       "negative: dequeueDeleteAt."
     when (index >= count) $
       error $
       "Index must be less " ++
       "than the count: dequeueDeleteAt."
     array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     count <- readIORef (dequeueCountRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     if index >= count `div` 2
       then do forM_ [index, index + 1 .. count - 2] $ \i ->
                 do x <- MV.read array ((start + i + 1) `mod` capacity)
                    MV.write array ((start + i) `mod` capacity) x
               MV.write array ((start + count - 1) `mod` capacity) undefined
       else do forM_ [index, index - 1 .. 1] $ \i ->
                 do x <- MV.read array ((start + i - 1) `mod` capacity)
                    MV.write array ((start + i) `mod` capacity) x
               let start' = (start + 1) `mod` capacity
               MV.write array start undefined
               start' `seq` writeIORef (dequeueStartRef dequeue) start'
     let count' = count - 1
     count' `seq` writeIORef (dequeueCountRef dequeue) count'
     
-- | Get the first element.
dequeueFirst :: Dequeue a -> IO a
{-# INLINE dequeueFirst #-}
dequeueFirst dequeue =
  do array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     MV.read array start
     
-- | Get the last element.
dequeueLast :: Dequeue a -> IO a
{-# INLINE dequeueLast #-}
dequeueLast dequeue =
  do array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     count <- readIORef (dequeueCountRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     MV.read array ((start + count - 1) `mod` capacity)
     
-- | Delete the last element.
dequeueDeleteLast :: Dequeue a -> IO ()
dequeueDeleteLast dequeue =
  do count <- readIORef (dequeueCountRef dequeue)
     when (count == 0) $
       error $
       "The dequeue cannot be empty: dequeueDeleteLast."
     array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     let end'   = (start + count - 1) `mod` capacity
         count' = count - 1
     end' `seq` MV.write array end' undefined
     count' `seq` writeIORef (dequeueCountRef dequeue) count'
     
-- | Delete the first element.
dequeueDeleteFirst :: Dequeue a -> IO ()
dequeueDeleteFirst dequeue =
  do count <- readIORef (dequeueCountRef dequeue)
     when (count == 0) $
       error $
       "The dequeue cannot be empty: dequeueDeleteFirst."
     array <- readIORef (dequeueArrayRef dequeue)
     start <- readIORef (dequeueStartRef dequeue)
     capacity <- readIORef (dequeueCapacityRef dequeue)
     let start' = (start + 1) `mod` capacity
         count' = count - 1
     MV.write array start undefined
     count' `seq` writeIORef (dequeueCountRef dequeue) count'
     start' `seq` writeIORef (dequeueStartRef dequeue) start'
