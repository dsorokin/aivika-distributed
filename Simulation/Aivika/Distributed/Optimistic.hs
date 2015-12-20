
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module re-exports the library functionality related to the optimistic strategy
-- of running distributed simulations.
--
module Simulation.Aivika.Distributed.Optimistic
       (-- * Modules
        module Simulation.Aivika.Distributed.Optimistic.DIO,
        module Simulation.Aivika.Distributed.Optimistic.Generator,
        module Simulation.Aivika.Distributed.Optimistic.Ref.Base,
        module Simulation.Aivika.Distributed.Optimistic.TimeServer) where

import Simulation.Aivika.Distributed.Optimistic.DIO
import Simulation.Aivika.Distributed.Optimistic.Generator
import Simulation.Aivika.Distributed.Optimistic.Ref.Base
import Simulation.Aivika.Distributed.Optimistic.TimeServer
