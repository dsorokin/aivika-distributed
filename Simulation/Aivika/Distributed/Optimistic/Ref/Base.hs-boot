
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Ref.Base
-- Copyright  : Copyright (c) 2009-2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This is an hs-boot file.
--
module Simulation.Aivika.Distributed.Optimistic.Ref.Base where

import Simulation.Aivika.Trans.Ref.Base
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

instance MonadRef DIO
