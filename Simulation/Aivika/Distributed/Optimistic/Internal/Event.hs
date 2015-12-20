
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
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Ref.Base
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
                 queuePQ :: Ref DIO (PQ.PriorityQueue (Point DIO -> DIO ())),
                 -- ^ the underlying priority queue
                 queueBusy :: Ref DIO Bool,
                 -- ^ whether the queue is currently processing events
                 queueTime :: Ref DIO Double
                 -- ^ the actual time of the event queue
               }

  newEventQueue specs = undefined

  enqueueEvent t m = undefined

  runEventWith processing m = undefined

  eventQueueCount = undefined
