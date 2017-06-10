
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
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
        inputMessageQueueSize,
        inputMessageQueueVersion,
        enqueueMessage,
        messageEnqueued,
        retryInputMessages,
        reduceInputMessages,
        filterInputMessages) where

import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp

data InputMessageQueue

newInputMessageQueue :: UndoableLog
                        -> (Bool -> TimeWarp DIO ())
                        -> (Bool -> TimeWarp DIO ())
                        -> TimeWarp DIO ()
                        -> DIO InputMessageQueue

inputMessageQueueSize :: InputMessageQueue -> IO Int

inputMessageQueueVersion :: InputMessageQueue -> IO Int

enqueueMessage :: InputMessageQueue -> Message -> TimeWarp DIO ()

messageEnqueued :: InputMessageQueue -> Signal DIO Message

retryInputMessages :: InputMessageQueue -> TimeWarp DIO ()

reduceInputMessages :: InputMessageQueue -> Double -> IO ()

filterInputMessages :: (Message -> Bool) -> InputMessageQueue -> IO [Message]
