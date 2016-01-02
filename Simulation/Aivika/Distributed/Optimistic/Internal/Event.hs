
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

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import {-# SOURCE #-} qualified Simulation.Aivika.Distributed.Optimistic.Internal.Ref as R
import qualified Simulation.Aivika.Distributed.Optimistic.PriorityQueue as PQ

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
                 queueTime :: R.Ref Double
                 -- ^ the actual time of the event queue
               }

  newEventQueue specs =
    do f <- R.newRef0 False
       t <- R.newRef0 $ spcStartTime specs
       pq <- R.newRef0 PQ.emptyQueue
       log <- newUndoableLog
       output <- newOutputMessageQueue
       input <- newInputMessageQueue (rollbackLog log) (rollbackMessages output)
       return EventQueue { queueInputMessages = input,
                           queueOutputMessages = output,
                           queueLog  = log,
                           queuePQ   = pq,
                           queueBusy = f,
                           queueTime = t }

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

-- | Expect the input message.
expectInputMessage :: Event DIO ()
expectInputMessage =
  Event $ \p ->
  do invokeEvent p processInputMessage
     invokeDynamics p processCurrentEvents

-- | Like 'expectInputMessage' but with a timeout in milliseconds.
expectInputMessageTimeout :: Int -> Event DIO ()
expectInputMessageTimeout = undefined

-- | Process an input message.
processInputMessage :: Event DIO ()
processInputMessage = undefined
