
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an input message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
       (InputMessageQueue,
        newInputMessageQueue,
        inputMessageQueueSize,
        inputMessageQueueVersion,
        enqueueMessage,
        messageEnqueued,
        retryInputMessages,
        reduceInputMessages,
        filterInputMessages) where

import Data.Maybe
import Data.List
import Data.IORef

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Vector
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Dynamics
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Specifies the input message queue.
data InputMessageQueue =
  InputMessageQueue { inputMessageLog :: UndoableLog,
                      -- ^ the Redo/Undo log.
                      inputMessageRollbackPre :: Bool -> TimeWarp DIO (),
                      -- ^ Rollback the operations till the specified time before actual changes either including the time or not.
                      inputMessageRollbackPost :: Bool -> TimeWarp DIO (),
                      -- ^ Rollback the operations till the specified time after actual changes either including the time or not.
                      inputMessageRollbackTime :: TimeWarp DIO (),
                      -- ^ Rollback the event time.
                      inputMessageSource :: SignalSource DIO Message,
                      -- ^ The message source.
                      inputMessages :: Vector InputMessageQueueItem,
                      -- ^ The input messages.
                      inputMessageActions :: IORef [Event DIO ()],
                      -- ^ The list of actions to perform.
                      inputMessageVersionRef :: IORef Int
                      -- ^ The number of reversions.
                    }

-- | Specified the input message queue item.
data InputMessageQueueItem =
  InputMessageQueueItem { itemMessage :: Message,
                          -- ^ The item message.
                          itemAnnihilated :: IORef Bool,
                          -- ^ Whether the item was annihilated.
                          itemProcessed :: IORef Bool
                          -- ^ Whether the item was processed.
                        }

-- | Create a new input message queue.
newInputMessageQueue :: UndoableLog
                        -- ^ the Redo/Undo log
                        -> (Bool -> TimeWarp DIO ())
                        -- ^ rollback operations till the specified time before actual changes either including the time or not
                        -> (Bool -> TimeWarp DIO ())
                        -- ^ rollback operations till the specified time after actual changes either including the time or not
                        -> TimeWarp DIO ()
                        -- ^ rollback the event time
                        -> DIO InputMessageQueue
newInputMessageQueue log rollbackPre rollbackPost rollbackTime =
  do ms <- liftIOUnsafe newVector
     r  <- liftIOUnsafe $ newIORef []
     s  <- newSignalSource0
     v  <- liftIOUnsafe $ newIORef 0
     return InputMessageQueue { inputMessageLog = log,
                                inputMessageRollbackPre = rollbackPre,
                                inputMessageRollbackPost = rollbackPost,
                                inputMessageRollbackTime = rollbackTime,
                                inputMessageSource = s,
                                inputMessages = ms,
                                inputMessageActions = r,
                                inputMessageVersionRef = v }

-- | Return the input message queue size.
inputMessageQueueSize :: InputMessageQueue -> IO Int
{-# INLINE inputMessageQueueSize #-}
inputMessageQueueSize = vectorCount . inputMessages

-- | Return the reversion count.
inputMessageQueueVersion :: InputMessageQueue -> IO Int
{-# INLINE inputMessageQueueVersion #-}
inputMessageQueueVersion = readIORef . inputMessageVersionRef

-- | Return a complement.
complement :: Int -> Int
complement x = - x - 1

-- | Raised when the message is enqueued.
messageEnqueued :: InputMessageQueue -> Signal DIO Message
messageEnqueued q = publishSignal (inputMessageSource q)

-- | Enqueue a new message ignoring the duplicated messages.
enqueueMessage :: InputMessageQueue -> Message -> TimeWarp DIO ()
enqueueMessage q m =
  TimeWarp $ \p ->
  do let t  = messageReceiveTime m
         t0 = pointTime p
     i <- liftIOUnsafe $ findAntiMessage q m
     case i of
       Nothing ->
         do -- skip the message duplicate
            logSkipInputMessage t0
            return ()
       Just i | i >= 0 ->
         do -- found the anti-message at the specified index
            when (t <= t0) $
              liftIOUnsafe $ modifyIORef' (inputMessageVersionRef q) (+ 1)
            item <- liftIOUnsafe $ readVector (inputMessages q) i
            f <- liftIOUnsafe $ readIORef (itemProcessed item)
            if f
              then do let p' = pastPoint t p
                      logRollbackInputMessages t0 t True
                      invokeTimeWarp p' $
                        rollbackInputMessages q True $
                        liftIOUnsafe $ annihilateMessage q m i
                      invokeTimeWarp p' $
                        inputMessageRollbackTime q
              else liftIOUnsafe $ annihilateMessage q m i
       Just i' | i' < 0 ->
         do -- insert the message at the specified right index
            when (t < t0) $
              liftIOUnsafe $ modifyIORef' (inputMessageVersionRef q) (+ 1)
            let i = complement i'
            if t < t0
              then do let p' = pastPoint t p
                      logRollbackInputMessages t0 t False
                      invokeTimeWarp p' $
                        rollbackInputMessages q False $
                        Event $ \p' ->
                        do liftIOUnsafe $ insertMessage q m i
                           invokeEvent p' $ activateMessage q i
                      invokeTimeWarp p' $
                        inputMessageRollbackTime q
              else do liftIOUnsafe $ insertMessage q m i
                      invokeEvent p $ activateMessage q i

-- | Log the message skip
logSkipInputMessage :: Double -> DIO ()
logSkipInputMessage t0 =
  logDIO NOTICE $
  "Skip the message at t = " ++ (show t0)

-- | Log the rollback.
logRollbackInputMessages :: Double -> Double -> Bool -> DIO ()
logRollbackInputMessages t0 t including =
  logDIO INFO $
  "Rollback at t = " ++ (show t0) ++ " --> " ++ (show t) ++
  (if not including then " not including" else "")

-- | Retry the computations.
retryInputMessages :: InputMessageQueue -> TimeWarp DIO ()
retryInputMessages q =
  TimeWarp $ \p ->
  do liftIOUnsafe $
       modifyIORef' (inputMessageVersionRef q) (+ 1)
     invokeTimeWarp p $
       rollbackInputMessages q True $
       return ()
     invokeTimeWarp p $
       inputMessageRollbackTime q

-- | Rollback the input messages till the specified time, either including the time or not, and apply the given computation.
rollbackInputMessages :: InputMessageQueue -> Bool -> Event DIO () -> TimeWarp DIO ()
rollbackInputMessages q including m =
  TimeWarp $ \p ->
  do liftIOUnsafe $
       requireEmptyMessageActions q
     invokeTimeWarp p $
       inputMessageRollbackPre q including
     invokeEvent p m
     invokeEvent p $
       performMessageActions q
     invokeTimeWarp p $
       inputMessageRollbackPost q including

-- | Return the point in the past.
pastPoint :: Double -> Point DIO -> Point DIO
pastPoint t p = p'
  where sc = pointSpecs p
        t0 = spcStartTime sc
        dt = spcDT sc
        n  = fromIntegral $ floor ((t - t0) / dt)
        p' = p { pointTime = t,
                 pointIteration = n,
                 pointPhase = -1 }

-- | Require that the there are no message actions.
requireEmptyMessageActions :: InputMessageQueue -> IO ()
requireEmptyMessageActions q =
  do xs <- readIORef (inputMessageActions q)
     unless (null xs) $
       error "There are incomplete message actions: requireEmptyMessageActions"

-- | Perform the message actions.
performMessageActions :: InputMessageQueue -> Event DIO ()
performMessageActions q =
  do xs <- liftIOUnsafe $ readIORef (inputMessageActions q)
     liftIOUnsafe $ writeIORef (inputMessageActions q) []
     sequence_ xs

-- | Return the leftmost index for the current time.
leftMessageIndex :: InputMessageQueue -> Double -> Int -> IO Int
leftMessageIndex q t i
  | i == 0    = return 0
  | otherwise = do let i' = i - 1
                   item' <- readVector (inputMessages q) i'
                   let m' = itemMessage item'
                       t' = messageReceiveTime m'
                   if t' > t
                     then error "Incorrect index: leftMessageIndex"
                     else if t' < t
                          then return i
                          else leftMessageIndex q t i'

-- | Find an anti-message and return the index; otherwise, return a complement to
-- the insertion index with the current receive time. The result is 'Nothing' if
-- the message is duplicated.
findAntiMessage :: InputMessageQueue -> Message -> IO (Maybe Int)
findAntiMessage q m =
  do right <- lookupRightMessageIndex q (messageReceiveTime m)
     if right < 0
       then return (Just right)
       else let loop i
                  | i < 0     = return (Just $ complement (right + 1))
                  | otherwise =
                    do item <- readVector (inputMessages q) i
                       let m' = itemMessage item
                           t  = messageReceiveTime m
                           t' = messageReceiveTime m'
                       if t' > t
                         then error "Incorrect index: findAntiMessage"
                         else if t' < t
                              then return (Just $ complement (right + 1))
                              else if antiMessages m m'
                                   then return (Just i)
                                   else if m == m'
                                        then return Nothing
                                        else loop (i - 1)
            in loop right       

-- | Annihilate a message at the specified index.
annihilateMessage :: InputMessageQueue -> Message -> Int -> IO ()
annihilateMessage q m i =
  do item <- readVector (inputMessages q) i
     let m' = itemMessage item
     unless (antiMessages m m') $
       error "Cannot annihilate another message: annihilateMessage"
     f <- readIORef (itemProcessed item)
     when f $
       error "Cannot annihilate the processed message: annihilateMessage"
     vectorDeleteAt (inputMessages q) i
     writeIORef (itemAnnihilated item) True

-- | Activate a message at the specified index.
activateMessage :: InputMessageQueue -> Int -> Event DIO ()
activateMessage q i =
  do item <- liftIOUnsafe $ readVector (inputMessages q) i
     let m    = itemMessage item
         loop =
           do f <- liftIOUnsafe $ readIORef (itemAnnihilated item)
              unless f $
                do writeLog (inputMessageLog q) $
                     liftIOUnsafe $
                     modifyIORef (inputMessageActions q) (loop :)
                   enqueueEvent (messageReceiveTime m) $
                     do f <- liftIOUnsafe $ readIORef (itemAnnihilated item)
                        unless f $
                          do writeLog (inputMessageLog q) $
                               liftIOUnsafe $
                               writeIORef (itemProcessed item) False
                             liftIOUnsafe $
                               writeIORef (itemProcessed item) True
                             unless (messageAntiToggle m) $
                               triggerSignal (inputMessageSource q) m
     loop

-- | Insert a new message.
insertMessage :: InputMessageQueue -> Message -> Int -> IO ()
-- insertMessage q m i =
--   do r1 <- newIORef False
--      r2 <- newIORef False
--      let item = InputMessageQueueItem m r1 r2
--      vectorInsert (inputMessages q) i item
insertMessage q m i =
  do n <- vectorCount (inputMessages q)
     when (i < n) $
       do item0 <- readVector (inputMessages q) i
          let m0 = itemMessage item0
          unless (messageReceiveTime m < messageReceiveTime m0) $
            error "Error inserting a new input message (check before): insertMessage"
     when (i > 0) $
       do item0 <- readVector (inputMessages q) (i - 1)
          let m0 = itemMessage item0
          unless (messageReceiveTime m >= messageReceiveTime m0) $
            error "Error inserting a new input message (check after): insertMessage"
     r1 <- newIORef False
     r2 <- newIORef False
     let item = InputMessageQueueItem m r1 r2
     vectorInsert (inputMessages q) i item

-- | Search for the rightmost message index.
lookupRightMessageIndex' :: InputMessageQueue -> Double -> Int -> Int -> IO Int
lookupRightMessageIndex' q t left right =
  if left > right
  then return $ complement (right + 1)
  else  
    do let index = ((left + 1) + right) `div` 2
       item <- readVector (inputMessages q) index
       let m' = itemMessage item
           t' = messageReceiveTime m'
       if left == right
         then if t' > t
              then return $ complement right
              else if t' < t
                   then return $ complement (right + 1)
                   else return right
         else if t' > t
              then lookupRightMessageIndex' q t left (index - 1)
              else if t' < t
                   then lookupRightMessageIndex' q t (index + 1) right
                   else lookupRightMessageIndex' q t index right

-- | Search for the leftmost message index.
lookupLeftMessageIndex' :: InputMessageQueue -> Double -> Int -> Int -> IO Int
lookupLeftMessageIndex' q t left right =
  if left > right
  then return $ complement left
  else  
    do let index = (left + right) `div` 2
       item <- readVector (inputMessages q) index
       let m' = itemMessage item
           t' = messageReceiveTime m'
       if left == right
         then if t' > t
              then return $ complement left
              else if t' < t
                   then return $ complement (left + 1)
                   else return left
         else if t' > t
              then lookupLeftMessageIndex' q t left (index - 1)
              else if t' < t
                   then lookupLeftMessageIndex' q t (index + 1) right
                   else lookupLeftMessageIndex' q t left index
 
-- | Search for the rightmost message index.
lookupRightMessageIndex :: InputMessageQueue -> Double -> IO Int
lookupRightMessageIndex q t =
  do n <- vectorCount (inputMessages q)
     lookupRightMessageIndex' q t 0 (n - 1)
 
-- | Search for the leftmost message index.
lookupLeftMessageIndex :: InputMessageQueue -> Double -> IO Int
lookupLeftMessageIndex q t =
  do n <- vectorCount (inputMessages q)
     lookupLeftMessageIndex' q t 0 (n - 1)

-- | Reduce the input messages till the specified time.
reduceInputMessages :: InputMessageQueue -> Double -> IO ()
reduceInputMessages q t =
  do count <- vectorCount (inputMessages q)
     len   <- loop count 0
     when (len > 0) $
       vectorDeleteRange (inputMessages q) 0 len
       where
         loop n i
           | i >= n    = return i
           | otherwise = do item <- readVector (inputMessages q) i
                            let m = itemMessage item
                            if messageReceiveTime m < t
                              then loop n (i + 1)
                              else return i

-- | Filter the input messages using the specified predicate.
filterInputMessages :: (Message -> Bool) -> InputMessageQueue -> IO [Message]
filterInputMessages pred q =
  do count <- vectorCount (inputMessages q)
     loop count 0 []
       where
         loop n i acc
           | i >= n    = return (reverse acc)
           | otherwise = do item <- readVector (inputMessages q) i
                            let m = itemMessage item
                            if pred m
                              then loop n (i + 1) (m : acc)
                              else loop n (i + 1) acc
