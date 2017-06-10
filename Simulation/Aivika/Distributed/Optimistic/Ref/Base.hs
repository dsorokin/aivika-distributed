
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Ref.Base
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- Here is an implementation of strict mutable references, where
-- 'DIO' is an instance of 'MonadRef' and 'MonadRef0'.
--
module Simulation.Aivika.Distributed.Optimistic.Ref.Base 
       (module Simulation.Aivika.Distributed.Optimistic.Ref.Base.Strict) where

import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Ref.Base

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Ref.Base.Strict
