
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
        retryEvent,
        syncEvent) where

import Data.Maybe
import Data.IORef
import Data.Typeable

import System.Timeout

import Control.Monad
import Control.Monad.Trans
import Control.Exception
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
                 queueBusy :: IORef Bool,
                 -- ^ whether the queue is currently processing events
                 queueTime :: IORef Double,
                 -- ^ the actual time of the event queue
                 queueGlobalTime :: IORef Double
                 -- ^ the global time
               }

  newEventQueue specs =
    do f <- liftIOUnsafe $ newIORef False
       t <- liftIOUnsafe $ newIORef $ spcStartTime specs
       gt <- liftIOUnsafe $ newIORef $ spcStartTime specs
       pq <- R.newRef0 PQ.emptyQueue
       log <- newUndoableLog
       output <- newOutputMessageQueue
       input <- newInputMessageQueue log rollbackEventPre rollbackEventPost rollbackEventTime
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
    do p0 <- invokeEvent p currentEventPoint
       invokeEvent p0 $ enqueueEvent (pointTime p) (return ())
       invokeEvent p $ syncEvents processing
       e p

  eventQueueCount =
    Event $ \p ->
    let pq = queuePQ $ runEventQueue $ pointRun p
    in invokeEvent p $
       fmap PQ.queueCount $ R.readRef pq

-- | The first stage of rolling the changes back.
rollbackEventPre :: Double -> Bool -> Event DIO ()
rollbackEventPre t including =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     rollbackLog (queueLog q) t including

-- | The post stage of rolling the changes back.
rollbackEventPost :: Double -> Bool -> Event DIO ()
rollbackEventPost t including =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     rollbackOutputMessages (queueOutputMessages q) t including

-- | Rollback the event time.
rollbackEventTime :: Double -> Event DIO ()
rollbackEventTime t =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     logDIO DEBUG $
       "Setting the queue time = " ++ show (pointTime p)
     ---
     liftIOUnsafe $ writeIORef (queueTime q) (pointTime p)
     t0 <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     when (t0 > t) $
       do ---
          logDIO DEBUG $
            "Setting the global time = " ++ show (pointTime p)
          ---
          liftIOUnsafe $ writeIORef (queueGlobalTime q) (pointTime p)
          invokeEvent p sendLocalTime

-- | Return the current event time.
currentEventTime :: Event DIO Double
{-# INLINE currentEventTime #-}
currentEventTime =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     liftIOUnsafe $ readIORef (queueTime q)

-- | Return the current event point.
currentEventPoint :: Event DIO (Point DIO)
{-# INLINE currentEventPoint #-}
currentEventPoint =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- liftIOUnsafe $ readIORef (queueTime q)
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
       f' <- liftIOUnsafe $ readIORef f
       if f'
         then error $
              "Detected an event loop, which may indicate to " ++
              "a logical error in the model: processPendingEventsCore"
         else do liftIOUnsafe $ writeIORef f True
                 call q p p
                 liftIOUnsafe $ writeIORef f False
  call q p p0 =
    do let pq = queuePQ q
           r  = pointRun p
       -- process external messages
       p1 <- invokeEvent p0 currentEventPoint
       ok <- invokeEvent p1 $ runTimeWarp processChannelMessages
       if not ok
         then call q p p1
         else do -- proceed with processing the events
                 f <- invokeEvent p1 $ fmap PQ.queueNull $ R.readRef pq
                 unless f $
                   do (t2, c2) <- invokeEvent p1 $ fmap PQ.queueFront $ R.readRef pq
                      let t = queueTime q
                      t' <- liftIOUnsafe $ readIORef t
                      when (t2 < t') $ 
                        -- error "The time value is too small: processPendingEventsCore"
                        error $
                        "The time value is too small (" ++ show t2 ++
                        " < " ++ show t' ++ "): processPendingEventsCore"
                      when ((t2 < pointTime p) ||
                            (includingCurrentEvents && (t2 == pointTime p))) $
                        do let sc = pointSpecs p
                               t0 = spcStartTime sc
                               dt = spcDT sc
                               n2 = fromIntegral $ floor ((t2 - t0) / dt)
                               p2 = p { pointTime = t2,
                                        pointIteration = n2,
                                        pointPhase = -1 }
                           ---
                           ps <- dioParams
                           when (dioLoggingPriority ps <= DEBUG) $
                             invokeEvent p2 $
                             writeLog (queueLog q) $
                             logDIO DEBUG $
                             "Reverting the queue time " ++ show t2 ++ " --> " ++ show t'
                           ---
                           liftIOUnsafe $ writeIORef t t2
                           invokeEvent p2 $ R.modifyRef pq PQ.dequeue
                           catchComp
                             (c2 p2)
                             (\RetryEvent -> invokeEvent p2 handleEventRetry) 
                           call q p p2

-- | Process the pending events synchronously, i.e. without past.
processPendingEvents :: Bool -> Dynamics DIO ()
processPendingEvents includingCurrentEvents = Dynamics r where
  r p =
    do let q = runEventQueue $ pointRun p
           t = queueTime q
       t' <- liftIOUnsafe $ readIORef t
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
          forM_ xs $ \x ->
            do p' <- invokeEvent p currentEventPoint
               invokeTimeWarp p' $ processChannelMessage x
     p' <- invokeEvent p currentEventPoint
     f2 <- invokeEvent p' isEventOverflow
     when f2 $
       invokeTimeWarp p' throttleMessageChannel

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
         invokeEvent p $
         updateGlobalTime t0
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
     invokeEvent p $
       updateGlobalTime globalTime
processChannelMessage x@TerminateLocalProcessMessage =
  TimeWarp $ \p ->
  do ---
     invokeEvent p $
       logMessage x
     ---
     liftDistributedUnsafe $
       DP.terminate

-- | Update the global time.
updateGlobalTime :: Double -> Event DIO ()
updateGlobalTime t =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- invokeEvent p currentEventTime
     if t > t'
       then logDIO WARNING $
            "t = " ++ show t' ++
            ": Ignored the global time that is greater than the current event time"
       else do liftIOUnsafe $
                 writeIORef (queueGlobalTime q) t
               invokeEvent p $
                 reduceEvents t

-- | Log the message at the specified time.
logMessage :: LocalProcessMessage -> Event DIO ()
logMessage (QueueMessage m) =
  Event $ \p ->
  logDIO INFO $
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

-- | Log that the local time is to be synchronized.
logSyncLocalTime :: Event DIO ()
logSyncLocalTime =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ", global t = " ++ (show t') ++
       ": synchronizing the local time..."

-- | Log that the local time is to be synchronized in ring 0.
logSyncLocalTime0 :: Event DIO ()
logSyncLocalTime0 =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ", global t = " ++ (show t') ++
       ": synchronizing the local time in ring 0..."

-- | Log that the local time is sent to the time server.
logSendLocalTime :: Event DIO ()
logSendLocalTime =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ", global t = " ++ (show t') ++
       ": sending the local time to the time server after delay..."

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

  liftIO m =
    Event $ \p ->
    do ok <- invokeEvent p $
             runTimeWarp $
             syncLocalTime $
             return ()
       if ok
         then liftIOUnsafe m
         else do f <- fmap dioAllowPrematureIO dioParams
                 if f
                   then do ---
                           invokeEvent p $ logPrematureIO
                           ---
                           liftIOUnsafe m
                   else error $
                        "Detected a premature IO action at t = " ++
                        (show $ pointTime p) ++ ": liftIO"

-- | Send the local time to the time server.
sendLocalTime :: Event DIO ()
sendLocalTime =
  Event $ \p ->
  do ---
     invokeEvent p logSendLocalTime
     ---
     t <- invokeEvent p currentEventTime
     sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       DP.send receiver (LocalTimeMessage sender t)
  
-- | Synchronize the local time executing the specified computation.
syncLocalTime :: Dynamics DIO () -> TimeWarp DIO ()
syncLocalTime m =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
         t = pointTime p
     invokeDynamics p m
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     if t' > t
       then error "Inconsistent time: syncLocalTime"
       else if t == spcStartTime (pointSpecs p)
            then return ()
            else do ---
                    invokeEvent p logSyncLocalTime
                    ---
                    ch <- messageChannel
                    dt <- fmap dioTimeServerMessageTimeout dioParams
                    f  <- liftIOUnsafe $
                          timeout dt $ awaitChannel ch
                    ok <- invokeEvent p $ runTimeWarp processChannelMessages
                    if ok
                      then do case f of
                                Just _  ->
                                  invokeTimeWarp p $ syncLocalTime m
                                Nothing ->
                                  do invokeEvent p sendLocalTime
                                     invokeTimeWarp p $ syncLocalTime0 m
                      else return ()
  
-- | Synchronize the local time executing the specified computation in ring 0.
syncLocalTime0 :: Dynamics DIO () -> TimeWarp DIO ()
syncLocalTime0 m =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
         t = pointTime p
     invokeDynamics p m
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     if t' > t
       then error "Inconsistent time: syncLocalTime0"
       else if t' == pointTime p
            then return ()
            else do ---
                    invokeEvent p logSyncLocalTime0
                    ---
                    ch <- messageChannel
                    dt <- fmap dioTimeServerMessageTimeout dioParams
                    f  <- liftIOUnsafe $
                          timeout dt $ awaitChannel ch
                    ok <- invokeEvent p $ runTimeWarp processChannelMessages
                    if ok
                      then do case f of
                                Just _  ->
                                  invokeTimeWarp p $ syncLocalTime m
                                Nothing ->
                                  error "Detected a deadlock when synchronizing the local time: syncLocalTime0"
                      else return ()

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
  do ok <- invokeEvent p $
           runTimeWarp $
           syncLocalTime $
           processEvents processing
     unless ok $
       invokeEvent p $
       syncEvents processing

-- | Synchronize the simulation in all nodes and call
-- the specified computation at the given modeling time.
--
-- It is rather safe to put 'liftIO' within this function.
syncEvent :: Double -> Event DIO () -> Event DIO ()
syncEvent t h =
  enqueueEvent t $
  Event $ \p ->
  do ok <- invokeEvent p $
           runTimeWarp $
           syncLocalTime $
           return ()
     when ok $
       invokeEvent p h

-- | An exception that signals of retrying the 'Event' computation.
data RetryEvent = RetryEvent
                  -- ^ The exception to retry the computation.
                deriving (Show, Typeable)

instance Exception RetryEvent where
  
  toException = toException . SomeException
  fromException x = do { SomeException a <- fromException x; cast a }

-- | Retry the 'Event' computation waiting for arriving other messages.
retryEvent :: Event DIO a
retryEvent = throwEvent RetryEvent

-- | Handle the 'Event' retry.
handleEventRetry :: Event DIO ()
handleEventRetry =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
         t = pointTime p
     ---
     logDIO NOTICE $
       "t = " ++ show t ++
       ": retrying the computations..."
     ---
     invokeTimeWarp p $
       retryInputMessages (queueInputMessages q)
     let loop =
           do ---
              logDIO DEBUG $
                "t = " ++ show t ++
                ": waiting for arriving a message..."
              ---
              ch <- messageChannel
              dt <- fmap dioTimeServerMessageTimeout dioParams
              f  <- liftIOUnsafe $
                    timeout dt $ awaitChannel ch
              ok <- invokeEvent p $ runTimeWarp processChannelMessages
              when ok $
                case f of
                  Just _  -> loop
                  Nothing -> loop0
         loop0 =
           do ---
              logDIO DEBUG $
                "t = " ++ show t ++
                ": waiting for arriving a message in ring 0..."
              ---
              ch <- messageChannel
              dt <- fmap dioTimeServerMessageTimeout dioParams
              f  <- liftIOUnsafe $
                    timeout dt $ awaitChannel ch
              ok <- invokeEvent p $ runTimeWarp processChannelMessages
              when ok $
                case f of
                  Just _  -> loop
                  Nothing ->
                    error "Detected a deadlock when retrying the computations: handleEventRetry"
     loop
