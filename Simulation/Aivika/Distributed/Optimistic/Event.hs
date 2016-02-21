
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
       (syncEvent) where

import Simulation.Aivika.Trans

import Simulation.Aivika.Distributed.Optimistic.Internal.Event
