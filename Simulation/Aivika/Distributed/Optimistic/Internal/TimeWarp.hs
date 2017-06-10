
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines a computation in the course of which the time may warp.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp
       (TimeWarp(..),
        invokeTimeWarp) where

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types

-- | The time warp computation.
newtype TimeWarp m a = TimeWarp (Point m -> m a)

-- | Invoke the 'TimeWarp' computation.
invokeTimeWarp :: Point m -> TimeWarp m a -> m a
{-# INLINE invokeTimeWarp #-}
invokeTimeWarp p (TimeWarp m) = m p
