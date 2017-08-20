
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Expect
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- Implements the 'expectProcess' function that allows waiting for some computation to have a determined result.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Expect
       (expectProcess) where

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Trans.Internal.Simulation
import Simulation.Aivika.Trans.Internal.Event
import Simulation.Aivika.Trans.Internal.Cont
import Simulation.Aivika.Trans.Internal.Process

import Simulation.Aivika.Distributed.Optimistic.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event

-- | Suspend the 'Process' until the specified computation is determined.
--  
-- The tested computation should depend on messages that come from other logical processes.
-- Moreover, the process must be initiated through the event queue.
--
-- In the current implementation there is a limitation that this function can be used only
-- once for the entire logical process simulation; otherwise, a race condition may arise.
expectProcess :: Event DIO (Maybe a) -> Process DIO a
expectProcess m =
  Process $ \pid ->
  Cont $ \c ->
  Event $ \p ->
  do let t = pointTime p
     invokeEvent p $
       expectEvent m $
       resumeCont c
