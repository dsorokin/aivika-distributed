
{-# LANGUAGE TypeFamilies, FlexibleInstances #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Event
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- The module defines an event queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Event
       (queueInputMessages,
        queueOutputMessages,
        queueLog) where

import Data.IORef

import System.Timeout

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import qualified Simulation.Aivika.PriorityQueue.Pure as PQ

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.Channel
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import {-# SOURCE #-} qualified Simulation.Aivika.Distributed.Optimistic.Internal.Ref as R

-- | An implementation of the 'EventQueueing' type class.
instance EventQueueing DIO where

  -- | The event queue type.
  data EventQueue DIO =
    EventQueue { queueInputMessages :: InputMessageQueue,
                 -- ^ the input message queue
                 queueOutputMessages :: OutputMessageQueue,
                 -- ^ the output message queue
                 queueLog :: UndoableLog,
                 -- ^ the undoable log of operations
                 queuePQ :: R.Ref (PQ.PriorityQueue (Point DIO -> DIO ())),
                 -- ^ the underlying priority queue
                 queueBusy :: R.Ref Bool,
                 -- ^ whether the queue is currently processing events
                 queueTime :: R.Ref Double,
                 -- ^ the actual time of the event queue
                 queueGlobalTime :: IORef Double
                 -- ^ the global time
               }

  newEventQueue specs =
    do f <- R.newRef0 False
       t <- R.newRef0 $ spcStartTime specs
       gt <- liftIOUnsafe $ newIORef $ spcStartTime specs
       pq <- R.newRef0 PQ.emptyQueue
       log <- newUndoableLog
       output <- newOutputMessageQueue
       input <- newInputMessageQueue log (rollbackLog log) (rollbackOutputMessages output)
       return EventQueue { queueInputMessages = input,
                           queueOutputMessages = output,
                           queueLog  = log,
                           queuePQ   = pq,
                           queueBusy = f,
                           queueTime = t,
                           queueGlobalTime = gt }

  enqueueEvent t (Event m) =
    Event $ \p ->
    let pq = queuePQ $ runEventQueue $ pointRun p
    in invokeEvent p $
       R.modifyRef pq $ \x -> PQ.enqueue x t m

  runEventWith processing (Event e) =
    Dynamics $ \p ->
    do invokeEvent p $ syncEvents processing
       e p

  eventQueueCount =
    Event $ \p ->
    let pq = queuePQ $ runEventQueue $ pointRun p
    in invokeEvent p $
       fmap PQ.queueCount $ R.readRef pq

-- | Return the current event point.
currentEventPoint :: Event DIO (Point DIO)
{-# INLINE currentEventPoint #-}
currentEventPoint =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- invokeEvent p $ R.readRef (queueTime q)
     if t' == pointTime p
       then return p
       else let sc = pointSpecs p
                t0 = spcStartTime sc
                dt = spcDT sc
                n' = fromIntegral $ floor ((t' - t0) / dt)
            in return p { pointTime = t',
                          pointIteration = n',
                          pointPhase = -1 }

-- | Process the pending events.
processPendingEventsCore :: Bool -> Dynamics DIO ()
processPendingEventsCore includingCurrentEvents = Dynamics r where
  r p =
    do let q = runEventQueue $ pointRun p
           f = queueBusy q
       p0 <- invokeEvent p currentEventPoint
       f' <- invokeEvent p0 $ R.readRef f
       unless f' $
         do invokeEvent p0 $ R.writeRef f True
            call q p p0
            p1 <- invokeEvent p0 currentEventPoint
            invokeEvent p1 $ R.writeRef f False
  call q p p0 =
    do let pq = queuePQ q
           r  = pointRun p
       -- process external messages
       p1 <- invokeEvent p0 currentEventPoint
       ok <- invokeEvent p1 $ runTimeWarp processChannelMessages
       if not ok
         then do p2 <- invokeEvent p1 currentEventPoint
                 call q p p2
         else do -- proceed with processing the events
                 f <- invokeEvent p1 $ fmap PQ.queueNull $ R.readRef pq
                 unless f $
                   do (t2, c2) <- invokeEvent p1 $ fmap PQ.queueFront $ R.readRef pq
                      let t = queueTime q
                      t' <- invokeEvent p1 $ R.readRef t
                      when (t2 < t') $ 
                        error "The time value is too small: processPendingEventsCore"
                      when ((t2 < pointTime p) ||
                            (includingCurrentEvents && (t2 == pointTime p))) $
                        do invokeEvent p1 $ R.writeRef t t2
                           invokeEvent p1 $ R.modifyRef pq PQ.dequeue
                           let sc = pointSpecs p
                               t0 = spcStartTime sc
                               dt = spcDT sc
                               n2 = fromIntegral $ floor ((t2 - t0) / dt)
                               p2 = p { pointTime = t2,
                                        pointIteration = n2,
                                        pointPhase = -1 }
                           c2 p2
                           call q p p2

-- | Process the pending events synchronously, i.e. without past.
processPendingEvents :: Bool -> Dynamics DIO ()
processPendingEvents includingCurrentEvents = Dynamics r where
  r p =
    do let q = runEventQueue $ pointRun p
           t = queueTime q
       t' <- invokeEvent p $ R.readRef t
       if pointTime p < t'
         then error $
              "The current time is less than " ++
              "the time in the queue: processPendingEvents"
         else invokeDynamics p m
  m = processPendingEventsCore includingCurrentEvents

-- | A memoized value.
processEventsIncludingCurrent :: Dynamics DIO ()
processEventsIncludingCurrent = processPendingEvents True

-- | A memoized value.
processEventsIncludingEarlier :: Dynamics DIO ()
processEventsIncludingEarlier = processPendingEvents False

-- | A memoized value.
processEventsIncludingCurrentCore :: Dynamics DIO ()
processEventsIncludingCurrentCore = processPendingEventsCore True

-- | A memoized value.
processEventsIncludingEarlierCore :: Dynamics DIO ()
processEventsIncludingEarlierCore = processPendingEventsCore True

-- | Process the events.
processEvents :: EventProcessing -> Dynamics DIO ()
processEvents CurrentEvents = processEventsIncludingCurrent
processEvents EarlierEvents = processEventsIncludingEarlier
processEvents CurrentEventsOrFromPast = processEventsIncludingCurrentCore
processEvents EarlierEventsOrFromPast = processEventsIncludingEarlierCore

-- | Whether there is an overflow.
isEventOverflow :: Event DIO Bool
isEventOverflow =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     n1 <- liftIOUnsafe $ logSize (queueLog q)
     n2 <- liftIOUnsafe $ inputMessageQueueIndex (queueInputMessages q)
     n3 <- liftIOUnsafe $ outputMessageQueueSize (queueOutputMessages q)
     ps <- dioParams
     let th1 = dioUndoableLogSizeThreshold ps
         th2 = dioInputMessageQueueIndexThreshold ps
         th3 = dioOutputMessageQueueSizeThreshold ps
     if (n1 >= th1) || (n2 >= th2) || (n3 >= th3)
       then do logDIO NOTICE $
                 "t = " ++ (show $ pointTime p) ++
                 ": detected the event overflow"
               return True
       else return False

-- | Throttle the message channel.
throttleMessageChannel :: TimeWarp DIO ()
throttleMessageChannel =
  TimeWarp $ \p ->
  do ch       <- messageChannel
     sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       DP.send receiver (LocalTimeMessage sender $ pointTime p)
     dt <- fmap dioTimeServerMessageTimeout dioParams
     liftIOUnsafe $
       timeout dt $ awaitChannel ch
     invokeTimeWarp p $ processChannelMessages

-- | Process the channel messages.
processChannelMessages :: TimeWarp DIO ()
processChannelMessages =
  TimeWarp $ \p ->
  do ch <- messageChannel
     f  <- liftIOUnsafe $ channelEmpty ch
     unless f $
       do xs <- liftIOUnsafe $ readChannel ch
          forM_ xs $
            invokeTimeWarp p . processChannelMessage
     f2 <- invokeEvent p isEventOverflow
     when f2 $
       invokeTimeWarp p throttleMessageChannel

-- | Process the channel message.
processChannelMessage :: LocalProcessMessage -> TimeWarp DIO ()
processChannelMessage x@(QueueMessage m) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     invokeEvent p $
       logMessage x
     ---
     t0 <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     when (messageReceiveTime m < t0) $
       do f <- fmap dioAllowProcessingOutdatedMessage dioParams
          if f
            then invokeEvent p logOutdatedMessage
            else error "Received the outdated message: processChannelMessage"
     invokeTimeWarp p $
       enqueueMessage (queueInputMessages q) m
processChannelMessage x@(GlobalTimeMessage globalTime) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
         t = pointTime p
     ---
     invokeEvent p $
       logMessage x
     ---
     case globalTime of
       Nothing -> return ()
       Just t0 ->
         do liftIOUnsafe $
              writeIORef (queueGlobalTime q) t0
            invokeEvent p $
              reduceEvents t0
     sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       DP.send receiver (GlobalTimeMessageResp sender t)
processChannelMessage x@(LocalTimeMessageResp globalTime) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     invokeEvent p $
       logMessage x
     ---
     liftIOUnsafe $
       writeIORef (queueGlobalTime q) globalTime
     invokeEvent p $
       reduceEvents globalTime
processChannelMessage x@TerminateLocalProcessMessage =
  TimeWarp $ \p ->
  do ---
     invokeEvent p $
       logMessage x
     ---
     liftDistributedUnsafe $
       DP.terminate

-- | Log the message at the specified time.
logMessage :: LocalProcessMessage -> Event DIO ()
logMessage (QueueMessage m) =
  Event $ \p ->
  logDIO DEBUG $
  "t = " ++ (show $ pointTime p) ++
  ": QueueMessage { " ++
  "sendTime = " ++ (show $ messageSendTime m) ++
  ", receiveTime = " ++ (show $ messageReceiveTime m) ++
  (if messageAntiToggle m then ", antiToggle = True" else "") ++
  " }"
logMessage m =
  Event $ \p ->
  logDIO DEBUG $
  "t = " ++ (show $ pointTime p) ++
  ": " ++ show m

-- | Log that the process is waiting for IO.
logWaitingForIO :: Event DIO ()
logWaitingForIO =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ", global t = " ++ (show t') ++
       ": waiting for IO..."

-- | Log an evidence of the premature IO.
logPrematureIO :: Event DIO ()
logPrematureIO =
  Event $ \p ->
  logDIO ERROR $
  "t = " ++ (show $ pointTime p) ++
  ": detected a premature IO action"

-- | Log an evidence of receiving the outdated message.
logOutdatedMessage :: Event DIO ()
logOutdatedMessage =
  Event $ \p ->
  logDIO ERROR $
  "t = " ++ (show $ pointTime p) ++
  ": received the outdated message"

-- | Log that the events must be synchronized.
logSyncEvents :: Event DIO ()
logSyncEvents =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ", global t = " ++ (show t') ++
       ": synchronizing the events..."

-- | Reduce events till the specified time.
reduceEvents :: Double -> Event DIO ()
reduceEvents t =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     liftIOUnsafe $
       do reduceInputMessages (queueInputMessages q) t
          reduceOutputMessages (queueOutputMessages q) t
          reduceLog (queueLog q) t

instance {-# OVERLAPPING #-} MonadIO (Event DIO) where

  liftIO m = loop
    where
      loop =
        Event $ \p ->
        do let q = runEventQueue $ pointRun p
               t = pointTime p
           t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
           if t' > t
             then error "Inconsistent time: liftIO"
             else if t' == pointTime p
                  then liftIOUnsafe m
                  else do ---
                          invokeEvent p logWaitingForIO
                          ---
                          sender   <- messageInboxId
                          receiver <- timeServerId
                          liftDistributedUnsafe $
                            DP.send receiver (LocalTimeMessage sender t)
                          ch <- messageChannel
                          dt <- fmap dioTimeServerMessageTimeout dioParams
                          liftIOUnsafe $
                            timeout dt $ awaitChannel ch
                          ok <- invokeEvent p $
                                runTimeWarp $
                                processChannelMessages
                          if ok
                            then invokeEvent p loop
                            else do f <- fmap dioAllowPrematureIO dioParams
                                    if f
                                      then do ---
                                              invokeEvent p $ logPrematureIO
                                              ---
                                              invokeEvent p loop
                                      else error $
                                           "Detected a premature IO action at t = " ++
                                           (show $ pointTime p) ++ ": liftIO"

-- | Run the computation and return a flag indicating whether there was no rollback.
runTimeWarp :: TimeWarp DIO () -> Event DIO Bool
runTimeWarp m =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     v0 <- liftIOUnsafe $ logRollbackVersion (queueLog q)
     invokeTimeWarp p m
     v2 <- liftIOUnsafe $ logRollbackVersion (queueLog q)
     return (v0 == v2)

-- | Synchronize the events.
syncEvents :: EventProcessing -> Event DIO ()
syncEvents processing =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
         t = pointTime p
     invokeDynamics p $
       processEvents processing
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     if t' > t
       then error "Inconsistent time: syncSimulation"
       else if t' == pointTime p
            then return ()
            else do ---
                    invokeEvent p logSyncEvents
                    ---
                    sender   <- messageInboxId
                    receiver <- timeServerId
                    liftDistributedUnsafe $
                      DP.send receiver (LocalTimeMessage sender t)
                    ch <- messageChannel
                    dt <- fmap dioTimeServerMessageTimeout dioParams
                    liftIOUnsafe $
                      timeout dt $ awaitChannel ch
                    invokeTimeWarp p $
                      processChannelMessages
                    invokeEvent p $
                      syncEvents processing
