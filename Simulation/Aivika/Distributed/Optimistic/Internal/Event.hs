
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
        queueLog,
        expectInputMessage,
        expectInputMessageTimeout,
        commitEvent) where

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
    do invokeDynamics p $ processEvents processing
       e p

  eventQueueCount =
    Event $ \p ->
    let pq = queuePQ $ runEventQueue $ pointRun p
    in invokeEvent p $
       fmap PQ.queueCount $ R.readRef pq

-- | Return the current event point.
currentEventPoint :: Dynamics DIO (Point DIO)
currentEventPoint =
  Dynamics $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- invokeEvent p $ R.readRef (queueTime q)
     let sc = pointSpecs p
         t0 = spcStartTime sc
         dt = spcDT sc
         n' = fromIntegral $ floor ((t' - t0) / dt)
     return p { pointTime = t',
                pointIteration = n',
                pointPhase = -1 }

-- | Process the pending events.
processPendingEventsCore :: Bool -> Dynamics DIO ()
processPendingEventsCore includingCurrentEvents = Dynamics r where
  r p =
    do let q = runEventQueue $ pointRun p
           f = queueBusy q
       p0 <- invokeDynamics p currentEventPoint
       f' <- invokeEvent p0 $ R.readRef f
       unless f' $
         do invokeEvent p0 $ R.writeRef f True
            p1 <- call q p p0
            invokeEvent p1 $ R.writeRef f False
  call q p p0 =
    do let pq = queuePQ q
           r  = pointRun p
       -- process external messages
       s <- invokeEvent p0 $ commitEvent processChannelMessages
       if not s
         then do p2 <- invokeDynamics p0 currentEventPoint
                 call q p p2
         else do -- proceed with processing the events
                 f <- invokeEvent p0 $ fmap PQ.queueNull $ R.readRef pq
                 if f
                   then return p0
                   else do (t2, c2) <- invokeEvent p0 $ fmap PQ.queueFront $ R.readRef pq
                           let t = queueTime q
                           t' <- invokeEvent p0 $ R.readRef t
                           when (t2 < t') $ 
                             error "The time value is too small: processPendingEventsCore"
                           if ((t2 < pointTime p) ||
                               (includingCurrentEvents && (t2 == pointTime p)))
                             then do invokeEvent p0 $ R.writeRef t t2
                                     invokeEvent p0 $ R.modifyRef pq PQ.dequeue
                                     let sc = pointSpecs p
                                         t0 = spcStartTime sc
                                         dt = spcDT sc
                                         n2 = fromIntegral $ floor ((t2 - t0) / dt)
                                         p2 = p { pointTime = t2,
                                                  pointIteration = n2,
                                                  pointPhase = -1 }
                                     c2 p2
                                     call q p p2
                             else return p0

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

-- | Process the current events only.
processCurrentEvents :: Event DIO ()
processCurrentEvents = Event r where
  r p =
    let q = runEventQueue $ pointRun p
        p0 = p
    in call q p p0
  call q p p0 =
    do let pq = queuePQ q
           r  = pointRun p
       -- process external messages
       invokeEvent p0 processChannelMessages
       -- proceed with processing the events
       f <- invokeEvent p0 $ fmap PQ.queueNull $ R.readRef pq
       unless f $
         do (t2, c2) <- invokeEvent p0 $ fmap PQ.queueFront $ R.readRef pq
            let t = queueTime q
            t' <- invokeEvent p0 $ R.readRef t
            when (t2 < t') $ 
              error "The time value is too small: processCurrentEvents"
            when (t2 == pointTime p) $
              do invokeEvent p0 $ R.writeRef t t2
                 invokeEvent p0 $ R.modifyRef pq PQ.dequeue
                 c2 p
                 call q p p0

-- | Expect any input message.
expectInputMessage :: Event DIO ()
expectInputMessage =
  Event $ \p ->
  do ---
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ": expecting an input message"
     ---
     ch <- messageChannel
     liftIOUnsafe $ awaitChannel ch
     invokeEvent p processCurrentEvents

-- | Like 'expectInputMessage' but with a timeout in microseconds.
expectInputMessageTimeout :: Int -> Event DIO Bool
expectInputMessageTimeout dt =
  Event $ \p ->
  do ---
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ": expecting an input message with timeout " ++ show dt
     ---
     ch <- messageChannel
     f  <- liftIOUnsafe $
           timeout dt $
           awaitChannel ch
     case f of
       Nothing -> return False
       Just _  ->
         do invokeEvent p processCurrentEvents
            return True

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
throttleMessageChannel :: Event DIO ()
throttleMessageChannel =
  Event $ \p ->
  do ch       <- messageChannel
     sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       DP.send receiver (LocalTimeMessage sender $ pointTime p)
     dt <- fmap dioTimeServerMessageTimeout dioParams
     liftIOUnsafe $
       timeout dt $ awaitChannel ch
     invokeEvent p $ processChannelMessages

-- | Process the channel messages.
processChannelMessages :: Event DIO ()
processChannelMessages =
  Event $ \p ->
  do ch <- messageChannel
     f  <- liftIOUnsafe $ channelEmpty ch
     unless f $
       do xs <- liftIOUnsafe $ readChannel ch
          forM_ xs $
            invokeEvent p . processChannelMessage
     f2 <- invokeEvent p isEventOverflow
     when f2 $
       invokeEvent p throttleMessageChannel

-- | Process the channel message.
processChannelMessage :: LocalProcessMessage -> Event DIO ()
processChannelMessage x@(QueueMessage m) =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     invokeEvent p $
       logMessage x
     ---
     invokeEvent p $
       enqueueMessage (queueInputMessages q) m
processChannelMessage x@(GlobalTimeMessage globalTime) =
  Event $ \p ->
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
  Event $ \p ->
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
  Event $ \p ->
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
                          s <- invokeEvent p $
                               commitEvent $
                               processChannelMessages
                          if s
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

-- | Try to commit an effect of the computation and
-- return a flag indicating whether there was no rollback.
commitEvent :: Event DIO () -> Event DIO Bool
commitEvent m =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     v0 <- liftIOUnsafe $ logRollbackVersion (queueLog q)
     invokeEvent p m
     v2 <- liftIOUnsafe $ logRollbackVersion (queueLog q)
     return (v0 == v2)
