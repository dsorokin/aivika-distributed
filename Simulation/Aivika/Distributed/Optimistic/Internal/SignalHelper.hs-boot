
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.SignalHelper
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This is an hs-boot file.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.SignalHelper
       (newDIOSignalSource0,
        handleDIOSignalComposite) where

import Simulation.Aivika.Trans

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

newDIOSignalSource0 :: DIO (SignalSource DIO a)

handleDIOSignalComposite :: Signal DIO a -> (a -> Event DIO ()) -> Composite DIO ()
