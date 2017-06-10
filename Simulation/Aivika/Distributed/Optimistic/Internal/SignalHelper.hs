
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.SignalHelper
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines a signal helper.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.SignalHelper
       (newDIOSignalSource0,
        handleDIOSignalComposite) where

import Simulation.Aivika.Trans

import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Create a new signal source in safe manner without constraints.
newDIOSignalSource0 :: DIO (SignalSource DIO a)
newDIOSignalSource0 = newSignalSource0

-- | Handle the signal in safe manner without constraints.
handleDIOSignalComposite :: Signal DIO a -> (a -> Event DIO ()) -> Composite DIO ()
handleDIOSignalComposite = handleSignalComposite
