
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Event
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines additional functions for the 'Event' computation.
--
module Simulation.Aivika.Distributed.Optimistic.Event
       (syncEvent,
        syncEventInStopTime) where

import Simulation.Aivika.Trans

import Simulation.Aivika.Distributed.Optimistic.Internal.Event
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Synchronize the simulation in all nodes and call
-- the specified computation in the stop time.
--
-- The modeling time must be initial when calling this function.
-- Also this call must be last in your part of the model.
--
-- It is rather safe to call 'liftIO' within this function.
syncEventInStopTime :: Event DIO () -> Simulation DIO ()
syncEventInStopTime h =
  do t0 <- liftParameter stoptime
     runEventInStartTime $
       syncEvent t0 h
     runEventInStopTime $
       return ()
