
{-# LANGUAGE MultiParamTypeClasses #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.DIO
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines 'DIO' as an instance of the 'MonadDES' type class.
--
module Simulation.Aivika.Distributed.Optimistic.DIO where

import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.DES
import Simulation.Aivika.Trans.Exception
import Simulation.Aivika.Trans.Generator
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Ref.Base
import Simulation.Aivika.Trans.QueueStrategy

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue

instance MonadDES DIO

instance MonadRef DIO

instance EventQueueing DIO

instance EnqueueStrategy DIO LCFS
instance EnqueueStrategy DIO FCFS

instance DequeueStrategy DIO LCFS
instance DequeueStrategy DIO FCFS

instance QueueStrategy DIO LCFS
instance QueueStrategy DIO FCFS

instance MonadComp DIO

instance MonadException DIO

instance MonadGenerator DIO
