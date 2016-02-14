
{-# LANGUAGE TypeFamilies #-}

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
        expectInputMessageTimeout) where

import Data.IORef

import System.Timeout

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import qualified Simulation.Aivika.PriorityQueue.Pure as PQ

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types

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

-- | Process the pending events.
processPendingEventsCore :: Bool -> Dynamics DIO ()
processPendingEventsCore includingCurrentEvents = Dynamics r where
  r p =
    do let q = runEventQueue $ pointRun p
           f = queueBusy q
       f' <- invokeEvent p $ R.readRef f
       unless f' $
         do invokeEvent p $ R.writeRef f True
            call q p
            invokeEvent p $ R.writeRef f False
  call q p =
    do let pq = queuePQ q
           r  = pointRun p
       -- process external messages
       invokeEvent p processChannelMessages
       -- proceed with processing the events
       f <- invokeEvent p $ fmap PQ.queueNull $ R.readRef pq
       unless f $
         do (t2, c2) <- invokeEvent p $ fmap PQ.queueFront $ R.readRef pq
            let t = queueTime q
            t' <- invokeEvent p $ R.readRef t
            when (t2 < t') $ 
              error "The time value is too small: processPendingEventsCore"
            when ((t2 < pointTime p) ||
                  (includingCurrentEvents && (t2 == pointTime p))) $
              do invokeEvent p $ R.writeRef t t2
                 invokeEvent p $ R.modifyRef pq PQ.dequeue
                 let sc = pointSpecs p
                     t0 = spcStartTime sc
                     dt = spcDT sc
                     n2 = fromIntegral $ floor ((t2 - t0) / dt)
                 c2 $ p { pointTime = t2,
                          pointIteration = n2,
                          pointPhase = -1 }
                 call q p

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
processCurrentEvents :: Dynamics DIO ()
processCurrentEvents = Dynamics r where
  r p =
    let q = runEventQueue $ pointRun p
    in call q p
  call q p =
    do let pq = queuePQ q
           r  = pointRun p
       -- process external messages
       invokeEvent p processChannelMessages
       -- proceed with processing the events
       f <- invokeEvent p $ fmap PQ.queueNull $ R.readRef pq
       unless f $
         do (t2, c2) <- invokeEvent p $ fmap PQ.queueFront $ R.readRef pq
            let t = queueTime q
            t' <- invokeEvent p $ R.readRef t
            when (t2 < t') $ 
              error "The time value is too small: processCurrentEvents"
            when (t2 == pointTime p) $
              do invokeEvent p $ R.writeRef t t2
                 invokeEvent p $ R.modifyRef pq PQ.dequeue
                 c2 p
                 call q p

-- | Expect any input message.
expectInputMessage :: Event DIO ()
expectInputMessage =
  Event $ \p ->
  do ch <- messageChannel
     liftIOUnsafe $ awaitChannel ch
     invokeDynamics p processCurrentEvents

-- | Like 'expectInputMessage' but with a timeout in milliseconds.
expectInputMessageTimeout :: Int -> Event DIO Bool
expectInputMessageTimeout dt =
  Event $ \p ->
  do ch <- messageChannel
     f  <- liftIOUnsafe $
           timeout (1000 * dt) $
           awaitChannel ch
     case f of
       Nothing -> return False
       Just _  ->
         do invokeDynamics p processCurrentEvents
            return True

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
     ---
     invokeEvent p $
       logMessage x
     ---
     liftIOUnsafe $
       writeIORef (queueGlobalTime q) globalTime
     invokeEvent p $
       reduceEvents globalTime
     t <- invokeEvent p $ R.readRef (queueTime q)
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
  liftDistributedUnsafe $
  DP.say $
  "t = " ++ (show $ pointTime p) ++ ": QueueMessage { " ++
  "sendTime=" ++ (show $ messageSendTime m) ++
  ", receiveTime=" ++ (show $ messageReceiveTime m) ++
  (if messageAntiToggle m then ", antiToggle=True" else "") ++
  "}"
logMessage m =
  Event $ \p ->
  liftDistributedUnsafe $
  DP.say $ "t = " ++ (show $ pointTime p) ++ ": " ++ show m

-- | Reduce events till the specified time.
reduceEvents :: Double -> Event DIO ()
reduceEvents t =
  Event $ \p ->
  do let q = runEventQueue $ pointRun p
     liftIOUnsafe $
       do reduceInputMessages (queueInputMessages q) t
          reduceOutputMessages (queueOutputMessages q) t
     reduceLog (queueLog q) t
