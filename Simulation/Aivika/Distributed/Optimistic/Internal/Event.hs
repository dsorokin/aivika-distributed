
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Event
-- Copyright  : Copyright (c) 2009-2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- The module defines an event queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Event
       (queueLog) where

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

  enqueueEvent t m = undefined

  runEventWith processing m = undefined

  eventQueueCount = undefined
