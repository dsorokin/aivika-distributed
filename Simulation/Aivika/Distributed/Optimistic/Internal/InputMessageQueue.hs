
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
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
        enqueueMessage,
        messageEnqueued,
        retryInputMessages,
        reduceInputMessages) where

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
                      inputMessageRollbackPre :: Double -> Bool -> Event DIO (),
                      -- ^ Rollback the operations till the specified time before actual changes either including the time or not.
                      inputMessageRollbackPost :: Double -> Bool -> Event DIO (),
                      -- ^ Rollback the operations till the specified time after actual changes either including the time or not.
                      inputMessageRollbackTime :: Double -> Event DIO (),
                      -- ^ Rollback the event time.
                      inputMessageSource :: SignalSource DIO Message,
                      -- ^ The message source.
                      inputMessages :: Vector InputMessageQueueItem,
                      -- ^ The input messages.
                      inputMessageActions :: IORef [Event DIO ()]
                      -- ^ The list of actions to perform.
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
                        -> (Double -> Bool -> Event DIO ())
                        -- ^ rollback operations till the specified time before actual changes either including the time or not
                        -> (Double -> Bool -> Event DIO ())
                        -- ^ rollback operations till the specified time after actual changes either including the time or not
                        -> (Double -> Event DIO ())
                        -- ^ rollback the event time
                        -> DIO InputMessageQueue
newInputMessageQueue log rollbackPre rollbackPost rollbackTime =
  do ms <- liftIOUnsafe newVector
     r  <- liftIOUnsafe $ newIORef []
     s  <- newSignalSource0
     return InputMessageQueue { inputMessageLog = log,
                                inputMessageRollbackPre = rollbackPre,
                                inputMessageRollbackPost = rollbackPost,
                                inputMessageRollbackTime = rollbackTime,
                                inputMessageSource = s,
                                inputMessages = ms,
                                inputMessageActions = r }

-- | Return the input message queue size.
inputMessageQueueSize :: InputMessageQueue -> IO Int
inputMessageQueueSize = vectorCount . inputMessages

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
       Nothing -> return ()
       Just i | i >= 0 ->
         do -- found the anti-message at the specified index
            item <- liftIOUnsafe $ readVector (inputMessages q) i
            f <- liftIOUnsafe $ readIORef (itemProcessed item)
            if f
              then do let p' = pastPoint t p
                      logRollbackInputMessages t0 t True
                      invokeEvent p' $
                        rollbackInputMessages q t True $
                        liftIOUnsafe $ annihilateMessage q i
                      invokeEvent p' $
                        inputMessageRollbackTime q t
              else liftIOUnsafe $ annihilateMessage q i
       Just i' | i' < 0 ->
         do -- insert the message at the specified right index
            let i = complement i'
            if t < t0
              then do let p' = pastPoint t p
                      logRollbackInputMessages t0 t False
                      invokeEvent p' $
                        rollbackInputMessages q t False $
                        Event $ \p' ->
                        do liftIOUnsafe $ insertMessage q m i
                           invokeEvent p' $ activateMessage q i
                      invokeEvent p' $
                        inputMessageRollbackTime q t
              else do liftIOUnsafe $ insertMessage q m i
                      invokeEvent p $ activateMessage q i

-- | Log the rollback.
logRollbackInputMessages :: Double -> Double -> Bool -> DIO ()
logRollbackInputMessages t0 t including =
  logDIO NOTICE $
  "Rollback at t = " ++ (show t0) ++ " --> " ++ (show t) ++
  (if not including then " not including" else "")

-- | Retry the computations.
retryInputMessages :: InputMessageQueue -> TimeWarp DIO ()
retryInputMessages q =
  TimeWarp $ \p ->
  do let t = pointTime p
     invokeEvent p $
       rollbackInputMessages q t True $
       return ()
     invokeEvent p $
       inputMessageRollbackTime q t

-- | Rollback the input messages till the specified time, either including the time or not, and apply the given computation.
rollbackInputMessages :: InputMessageQueue -> Double -> Bool -> Event DIO () -> Event DIO ()
rollbackInputMessages q t including m =
  Event $ \p ->
  do liftIOUnsafe $
       requireEmptyMessageActions q
     invokeEvent p $
       inputMessageRollbackPre q t including
     invokeEvent p m
     invokeEvent p $
       performMessageActions q
     invokeEvent p $
       inputMessageRollbackPost q t including

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
annihilateMessage :: InputMessageQueue -> Int -> IO ()
annihilateMessage q i =
  do item <- readVector (inputMessages q) i
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
insertMessage q m i =
  do r1 <- newIORef False
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

