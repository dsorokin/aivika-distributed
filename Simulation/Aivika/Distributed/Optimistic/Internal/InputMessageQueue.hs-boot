
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This is an hs-boot file.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
       (InputMessageQueue,
        newInputMessageQueue,
        inputMessageQueueIndex,
        inputMessageQueueSize,
        enqueueMessage,
        messageEnqueued,
        reduceInputMessages) where

import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp

data InputMessageQueue

newInputMessageQueue :: UndoableLog
                        -> (Double -> Bool -> Event DIO ())
                        -> (Double -> Bool -> Event DIO ())
                        -> (Double -> Event DIO ())
                        -> DIO InputMessageQueue

inputMessageQueueIndex :: InputMessageQueue -> IO Int

inputMessageQueueSize :: InputMessageQueue -> IO Int

enqueueMessage :: InputMessageQueue -> Message -> TimeWarp DIO ()

messageEnqueued :: InputMessageQueue -> Signal DIO Message

reduceInputMessages :: InputMessageQueue -> Double -> IO ()
