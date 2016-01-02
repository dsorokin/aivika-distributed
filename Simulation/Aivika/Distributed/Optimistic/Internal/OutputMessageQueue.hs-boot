
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This is an hs-boot file.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
       (OutputMessageQueue,
        newOutputMessageQueue,
        sendMessage,
        rollbackMessages) where

import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

data OutputMessageQueue

newOutputMessageQueue :: DIO OutputMessageQueue

sendMessage :: OutputMessageQueue -> Message -> Event DIO ()

rollbackMessages :: OutputMessageQueue -> Double -> Event DIO ()

