
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.AcknowledgementMessageQueue
-- Copyright  : Copyright (c) 2015-2018, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This is an hs-boot file.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.AcknowledgementMessageQueue
       (AcknowledgementMessageQueue,
        newAcknowledgementMessageQueue,
        acknowledgementMessageQueueSize,
        enqueueAcknowledgementMessage,
        reduceAcknowledgementMessages,
        filterAcknowledgementMessages) where

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO

data AcknowledgementMessageQueue

newAcknowledgementMessageQueue :: DIO AcknowledgementMessageQueue

acknowledgementMessageQueueSize :: AcknowledgementMessageQueue -> IO Int

enqueueAcknowledgementMessage :: AcknowledgementMessageQueue -> AcknowledgementMessage -> IO ()

reduceAcknowledgementMessages :: AcknowledgementMessageQueue -> Double -> IO ()

filterAcknowledgementMessages :: (AcknowledgementMessage -> Bool) -> AcknowledgementMessageQueue -> IO [AcknowledgementMessage]
