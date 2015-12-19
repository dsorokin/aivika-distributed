
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
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
        enqueueMessage) where

import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

data InputMessageQueue

newInputMessageQueue :: (Double -> Event DIO ())
                        -> (Double -> Event DIO ())
                        -> SignalSource DIO Message
                        -> Simulation DIO InputMessageQueue

enqueueMessage :: InputMessageQueue -> Message -> Event DIO ()
