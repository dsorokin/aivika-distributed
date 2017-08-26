
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, OverlappingInstances #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.DIO
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines 'DIO' as an instance of the 'MonadDES' and 'EventIOQueueing' type classes.
--
module Simulation.Aivika.Distributed.Optimistic.DIO
       (DIO,
        DIOParams(..),
        DIOStrategy(..),
        runDIO,
        defaultDIOParams,
        dioParams,
        messageInboxId,
        timeServerId,
        logDIO,
        terminateDIO,
        registerDIO,
        unregisterDIO,
        monitorProcessDIO,
        InboxProcessMessage(MonitorProcessMessage),
        processMonitorSignal) where

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.DES
import Simulation.Aivika.Trans.Exception
import Simulation.Aivika.Trans.Generator
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Composite
import Simulation.Aivika.Trans.Process
import Simulation.Aivika.Trans.Ref.Base
import Simulation.Aivika.Trans.QueueStrategy
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
import {-# SOURCE #-} Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
import Simulation.Aivika.Distributed.Optimistic.Generator
import Simulation.Aivika.Distributed.Optimistic.Ref.Base.Lazy
import Simulation.Aivika.Distributed.Optimistic.Ref.Base.Strict
import Simulation.Aivika.Distributed.Optimistic.QueueStrategy

instance MonadDES DIO

instance MonadComp DIO

instance {-# OVERLAPPING #-} MonadIO (Process DIO) where
  liftIO = liftEvent . liftIO

instance {-# OVERLAPPING #-} MonadIO (Composite DIO) where
  liftIO = liftEvent . liftIO
