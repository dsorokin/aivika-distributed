
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.DIO
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines 'DIO' as an instance of the 'MonadDES' type class.
--
module Simulation.Aivika.Distributed.Optimistic.DIO
       (DIO,
        DIOParams(..),
        runDIO,
        defaultDIOParams,
        dioParams,
        messageInboxId,
        timeServerId,
        terminateSimulation,
        unregisterSimulation) where

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.DES
import Simulation.Aivika.Trans.Exception
import Simulation.Aivika.Trans.Generator
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Process
import Simulation.Aivika.Trans.Ref.Base
import Simulation.Aivika.Trans.QueueStrategy

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
import Simulation.Aivika.Distributed.Optimistic.Generator
import Simulation.Aivika.Distributed.Optimistic.Ref.Base
import Simulation.Aivika.Distributed.Optimistic.QueueStrategy

instance MonadDES DIO

instance MonadComp DIO

instance {-# OVERLAPPING #-} MonadIO (Process DIO) where
  liftIO = liftEvent . liftIO

