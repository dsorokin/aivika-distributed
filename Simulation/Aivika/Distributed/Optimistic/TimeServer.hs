
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.TimeServer
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module allows running the time server that coordinates the global simulation time.
--
module Simulation.Aivika.Distributed.Optimistic.TimeServer
       (TimeServerParams(..),
        defaultTimeServerParams,
        timeServer,
        curryTimeServer) where

import Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
