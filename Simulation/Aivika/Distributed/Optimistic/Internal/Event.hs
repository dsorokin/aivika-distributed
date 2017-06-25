
{-# LANGUAGE TypeFamilies, FlexibleInstances, OverlappingInstances #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Event
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
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
        expectEvent,
        processMonitorSignal) where

import Data.Maybe
import Data.IORef
import Data.Time.Clock

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
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.SignalHelper
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
import Simulation.Aivika.Distributed.Optimistic.Internal.TransientMessageQueue
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import {-# SOURCE #-} qualified Simulation.Aivika.Distributed.Optimistic.Internal.Ref.Strict as R

-- | Convert microseconds to seconds.
microsecondsToSeconds :: Int -> Rational
microsecondsToSeconds x = (fromInteger $ toInteger x) / 1000000

-- | An implementation of the 'EventQueueing' type class.
instance EventQueueing DIO where

  -- | The event queue type.
  data EventQueue DIO =
    EventQueue { queueInputMessages :: InputMessageQueue,
                 -- ^ the input message queue
                 queueOutputMessages :: OutputMessageQueue,
                 -- ^ the output message queue
                 queueTransientMessages :: TransientMessageQueue,
                 -- ^ the transient message queue
                 queueLog :: UndoableLog,
                 -- ^ the undoable log of operations
                 queuePQ :: R.Ref (PQ.PriorityQueue (Point DIO -> DIO ())),
                 -- ^ the underlying priority queue
                 queueBusy :: IORef Bool,
                 -- ^ whether the queue is currently processing events
                 queueTime :: IORef Double,
                 -- ^ the actual time of the event queue
                 queueGlobalTime :: IORef Double,
                 -- ^ the global time
                 queueInFind :: IORef Bool,
                 -- ^ whether the queue is in find mode
                 queueProcessMonitorNotificationSource :: SignalSource DIO DP.ProcessMonitorNotification
                 -- ^ the source of process monitor notifications
               }

  newEventQueue specs =
    do f <- liftIOUnsafe $ newIORef False
       t <- liftIOUnsafe $ newIORef $ spcStartTime specs
       gt <- liftIOUnsafe $ newIORef $ spcStartTime specs
       pq <- R.newRef0 PQ.emptyQueue
       log <- newUndoableLog
       transient <- newTransientMessageQueue
       output <- newOutputMessageQueue $ enqueueTransientMessage transient
       input <- newInputMessageQueue log rollbackEventPre rollbackEventPost rollbackEventTime
       infind <- liftIOUnsafe $ newIORef False
       s <- newDIOSignalSource0
       return EventQueue { queueInputMessages = input,
                           queueOutputMessages = output,
                           queueTransientMessages = transient,
                           queueLog  = log,
                           queuePQ   = pq,
                           queueBusy = f,
                           queueTime = t,
                           queueGlobalTime = gt,
                           queueInFind = infind,
                           queueProcessMonitorNotificationSource = s }

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
rollbackEventPre :: Bool -> TimeWarp DIO ()
rollbackEventPre including =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     rollbackLog (queueLog q) (pointTime p) including

-- | The post stage of rolling the changes back.
rollbackEventPost :: Bool -> TimeWarp DIO ()
rollbackEventPost including =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     rollbackOutputMessages (queueOutputMessages q) (pointTime p) including

-- | Rollback the event time.
rollbackEventTime :: TimeWarp DIO ()
rollbackEventTime =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
         t = pointTime p
     ---
     --- logDIO DEBUG $
     ---   "Setting the queue time = " ++ show t
     ---
     liftIOUnsafe $ writeIORef (queueTime q) t
     t0 <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     when (t0 > t) $
       do ---
          --- logDIO DEBUG $
          ---   "Setting the global time = " ++ show t
          ---
          liftIOUnsafe $ writeIORef (queueGlobalTime q) t

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
                           --- ps <- dioParams
                           --- when (dioLoggingPriority ps <= DEBUG) $
                           ---   invokeEvent p2 $
                           ---   writeLog (queueLog q) $
                           ---   logDIO DEBUG $
                           ---   "Reverting the queue time " ++ show t2 ++ " --> " ++ show t'
                           ---
                           liftIOUnsafe $ writeIORef t t2
                           invokeEvent p2 $ R.modifyRef pq PQ.dequeue
                           catchComp
                             (c2 p2)
                             (\e@(SimulationRetry _) -> invokeEvent p2 $ handleEventRetry e) 
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
     n2 <- liftIOUnsafe $ outputMessageQueueSize (queueOutputMessages q)
     n3 <- liftIOUnsafe $ transientMessageQueueSize (queueTransientMessages q)
     ps <- dioParams
     let th1 = dioUndoableLogSizeThreshold ps
         th2 = dioOutputMessageQueueSizeThreshold ps
         th3 = dioTransientMessageQueueSizeThreshold ps
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
  do -- invokeEvent p requestGlobalTime
     ch <- messageChannel
     dt <- fmap dioSyncTimeout dioParams
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
     --- invokeEvent p $
     ---   logMessage x
     ---
     infind <- liftIOUnsafe $ readIORef (queueInFind q)
     deliverAcknowledgmentMessage (acknowledgmentMessage infind m)
     t0 <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     p' <- invokeEvent p currentEventPoint
     if messageReceiveTime m < t0
       then do f <- fmap dioAllowSkippingOutdatedMessage dioParams
               if f
                 then invokeEvent p' logOutdatedMessage
                 else error "Received the outdated message: processChannelMessage"
       else invokeTimeWarp p' $
            enqueueMessage (queueInputMessages q) m
processChannelMessage x@(QueueMessageBulk ms) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     infind <- liftIOUnsafe $ readIORef (queueInFind q)
     deliverAcknowledgmentMessages $ map (acknowledgmentMessage infind) ms
     t0 <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     forM_ ms $ \m ->
       do p' <- invokeEvent p currentEventPoint
          if messageReceiveTime m < t0
            then do f <- fmap dioAllowSkippingOutdatedMessage dioParams
                    if f
                      then invokeEvent p' logOutdatedMessage
                      else error "Received the outdated message: processChannelMessage"
            else invokeTimeWarp p' $
                 enqueueMessage (queueInputMessages q) m
processChannelMessage x@(AcknowledgmentQueueMessage m) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     liftIOUnsafe $
       processAcknowledgmentMessage (queueTransientMessages q) m
processChannelMessage x@(AcknowledgmentQueueMessageBulk ms) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     liftIOUnsafe $
       forM_ ms $
       processAcknowledgmentMessage (queueTransientMessages q)
processChannelMessage x@ComputeLocalTimeMessage =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     liftIOUnsafe $
       writeIORef (queueInFind q) True
     t' <- invokeEvent p getLocalTime
     sender   <- messageInboxId
     receiver <- timeServerId
     sendLocalTimeDIO receiver sender t'
processChannelMessage x@(GlobalTimeMessage globalTime) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     liftIOUnsafe $
       do writeIORef (queueInFind q) False
          resetAcknowledgmentMessageTime (queueTransientMessages q)
     invokeEvent p $
       updateGlobalTime globalTime
processChannelMessage x@(ProcessMonitorNotificationMessage y@(DP.ProcessMonitorNotification _ pid reason)) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     invokeEvent p $
       triggerSignal (queueProcessMonitorNotificationSource q) y
processChannelMessage x@(ReconnectProcessMessage pid) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     invokeEvent p $
       reconnectProcess pid
processChannelMessage x@(KeepAliveLocalProcessMessage m) =
  TimeWarp $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logMessage x
     ---
     return ()

-- | Return the local minimum time.
getLocalTime :: Event DIO Double
getLocalTime =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t1 <- liftIOUnsafe $ readIORef (queueTime q)
     t2 <- liftIOUnsafe $ transientMessageQueueTime (queueTransientMessages q)
     t3 <- liftIOUnsafe $ acknowledgmentMessageTime (queueTransientMessages q)
     let t' = t1 `min` t2 `min` t3
     ---
     --- n <- liftIOUnsafe $ transientMessageQueueSize (queueTransientMessages q)
     --- logDIO ERROR $
     ---   "t = " ++ show (pointTime p) ++
     ---   ": queue time = " ++ show t1 ++
     ---   ", unacknowledged time = " ++ show t2 ++
     ---   ", marked acknowledged time = " ++ show t3 ++
     ---   ", transient queue size = " ++ show n ++
     ---   " -> " ++ show t'
     ---
     return t'

-- | Update the global time.
updateGlobalTime :: Double -> Event DIO ()
updateGlobalTime t =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- invokeEvent p getLocalTime
     if t > t'
       then logDIO WARNING $
            "t = " ++ show t' ++
            ": Ignored the global time that is greater than the current local time"
       else do liftIOUnsafe $
                 writeIORef (queueGlobalTime q) t
               invokeEvent p $
                 reduceEvents t

-- | Request for the global minimum time.
requestGlobalTime :: Event DIO ()
requestGlobalTime =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     --- invokeEvent p $
     ---   logRequestGlobalTime
     ---
     sender   <- messageInboxId
     receiver <- timeServerId
     sendRequestGlobalTimeDIO receiver sender

-- | Show the message.
showMessage :: Message -> ShowS
showMessage m =
  showString "{ " .
  showString "sendTime = " .
  shows (messageSendTime m) .
  showString ", receiveTime = " .
  shows (messageReceiveTime m) .
  (if messageAntiToggle m
   then showString ", antiToggle = True"
   else showString "") .
  showString " }"

-- | Log the message at the specified time.
logMessage :: LocalProcessMessage -> Event DIO ()
logMessage (QueueMessage m) =
  Event $ \p ->
  logDIO INFO $
  "t = " ++ (show $ pointTime p) ++
  ": QueueMessage " ++
  showMessage m []
logMessage (QueueMessageBulk ms) =
  Event $ \p ->
  logDIO INFO $
  "t = " ++ (show $ pointTime p) ++
  ": QueueMessageBulk [ " ++
  let fs = foldl1 (\a b -> a . showString ", " . b) $ map showMessage ms
  in fs [] ++ " ]" 
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

-- | Log that the global time is requested.
logRequestGlobalTime :: Event DIO ()
logRequestGlobalTime =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     t' <- liftIOUnsafe $ readIORef (queueGlobalTime q)
     logDIO DEBUG $
       "t = " ++ (show $ pointTime p) ++
       ", global t = " ++ (show t') ++
       ": requesting for a new global time..."

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
  logDIO WARNING $
  "t = " ++ (show $ pointTime p) ++
  ": skipping the outdated message"

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
                           --- invokeEvent p $ logPrematureIO
                           ---
                           liftIOUnsafe m
                   else error $
                        "Detected a premature IO action at t = " ++
                        (show $ pointTime p) ++ ": liftIO"

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
       else if (t == spcStartTime (pointSpecs p)) || (t' == pointTime p)
            then return ()
            else do ---
                    --- invokeEvent p logSyncLocalTime
                    ---
                    ch <- messageChannel
                    dt <- fmap dioSyncTimeout dioParams
                    f  <- liftIOUnsafe $
                          timeout dt $ awaitChannel ch
                    ok <- invokeEvent p $ runTimeWarp processChannelMessages
                    if ok
                      then do case f of
                                Just _  ->
                                  invokeTimeWarp p $ syncLocalTime m
                                Nothing ->
                                  do -- invokeEvent p requestGlobalTime
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
                    --- invokeEvent p logSyncLocalTime0
                    ---
                    ch <- messageChannel
                    dt <- fmap dioSyncTimeout dioParams
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
     v0 <- liftIOUnsafe $ inputMessageQueueVersion (queueInputMessages q)
     invokeTimeWarp p m
     v2 <- liftIOUnsafe $ inputMessageQueueVersion (queueInputMessages q)
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

-- | 'DIO' is an instance of 'EventIOQueueing'.
instance EventIOQueueing DIO where

  enqueueEventIO t h =
    enqueueEvent t $
    Event $ \p ->
    do ok <- invokeEvent p $
             runTimeWarp $
             syncLocalTime $
             return ()
       when ok $
         invokeEvent p h

-- | Handle the 'Event' retry.
handleEventRetry :: SimulationRetry -> Event DIO ()
handleEventRetry e =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
         t = pointTime p
     ---
     logDIO INFO $
       "t = " ++ show t ++
       ": retrying the computations..."
     ---
     invokeTimeWarp p $
       retryInputMessages (queueInputMessages q)
     let loop =
           do ---
              --- logDIO DEBUG $
              ---   "t = " ++ show t ++
              ---   ": waiting for arriving a message..."
              ---
              ch <- messageChannel
              dt <- fmap dioSyncTimeout dioParams
              f  <- liftIOUnsafe $
                    timeout dt $ awaitChannel ch
              ok <- invokeEvent p $ runTimeWarp processChannelMessages
              when ok $
                case f of
                  Just _  -> loop
                  Nothing -> loop0
         loop0 =
           do ---
              --- logDIO DEBUG $
              ---   "t = " ++ show t ++
              ---   ": waiting for arriving a message in ring 0..."
              ---
              ch <- messageChannel
              dt <- fmap dioSyncTimeout dioParams
              f  <- liftIOUnsafe $
                    timeout dt $ awaitChannel ch
              ok <- invokeEvent p $ runTimeWarp processChannelMessages
              when ok $
                case f of
                  Just _  -> loop
                  Nothing ->
                    error $
                    "Detected a deadlock when retrying the computations: handleEventRetry\n" ++
                    "--- the nested exception ---\n" ++ show e 
     loop

-- | Reconnect to the remote process.
reconnectProcess :: DP.ProcessId -> Event DIO ()
reconnectProcess pid =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     ---
     logDIO NOTICE $
       "t = " ++ show (pointTime p) ++
       ": reconnecting to " ++ show pid ++ "..."
     ---
     infind <- liftIOUnsafe $ readIORef (queueInFind q)
     let ys = queueInputMessages q
     ys' <- liftIOUnsafe $
            fmap (map $ acknowledgmentMessage infind) $
            filterInputMessages (\x -> messageSenderId x == pid) ys
     unless (null ys') $
       sendAcknowledgmentMessagesDIO pid ys'
     xs <- liftIOUnsafe $ transientMessages (queueTransientMessages q)
     let xs' = filter (\x -> messageReceiverId x == pid) xs
     unless (null xs') $
       sendMessagesDIO pid xs'

-- | A signal triggered when coming the process monitor notification from the Cloud Haskell back-end.
processMonitorSignal :: Signal DIO DP.ProcessMonitorNotification
processMonitorSignal =
  Signal { handleSignal = \h ->
            Event $ \p ->
            let q = runEventQueue (pointRun p)
                s = publishSignal (queueProcessMonitorNotificationSource q)
            in invokeEvent p $
               handleSignal s h
         }

-- | Suspend the 'Event' computation until the specified predicate is satisfied.
-- The predicate should depend on messages that come from other local processes.
--
-- The function call should be placed in 'enqueueEvent' so that the computation
-- would be called repeatedely in case of roll-backs.
expectEvent :: Event DIO Bool -> Event DIO ()
expectEvent m =
  Event $ \p ->
  do let t = pointTime p
     ---
     logDIO INFO $
       "t = " ++ show t ++
       ": expecting the event..."
     ---
     let loop =
           do x <- invokeEvent p m
              case x of
                True  -> return ()
                False ->
                  do ---
                     --- logDIO DEBUG $
                     ---   "t = " ++ show t ++
                     ---   ": waiting for the event..."
                     ---
                     ch <- messageChannel
                     dt <- fmap dioSyncTimeout dioParams
                     f  <- liftIOUnsafe $
                           timeout dt $ awaitChannel ch
                     ok <- invokeEvent p $ runTimeWarp processChannelMessages
                     when ok $
                       case f of
                         Just _  -> loop
                         Nothing -> loop0
         loop0 =
           do x <- invokeEvent p m
              case x of
                True  -> return ()
                False ->
                  do ---
                     --- logDIO DEBUG $
                     ---   "t = " ++ show t ++
                     ---   ": waiting for the event in ring 0..."
                     ---
                     ch <- messageChannel
                     dt <- fmap dioSyncTimeout dioParams
                     f  <- liftIOUnsafe $
                           timeout dt $ awaitChannel ch
                     ok <- invokeEvent p $ runTimeWarp processChannelMessages
                     when ok $
                       case f of
                         Just _  -> loop
                         Nothing ->
                           error "Detected a deadlock when expecting the event: expectEvent"
     loop
