
{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines the Time Server that coordinates the global simulation time.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
       (TimeServer) where

import GHC.Generics

import Data.Typeable
import Data.Binary

-- | The Time Server that coordinates the global simulation time.
data TimeServer = TimeServer
