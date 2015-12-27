
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Message
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines functions for working with messages.
--
module Simulation.Aivika.Distributed.Optimistic.Message
       (sendMessage,
        enqueueMessage,
        expectMessage,
        expectMessageTimeout,
        messageReceived) where

import Control.Distributed.Process (ProcessId)
import Control.Distributed.Process.Serializable

import Simulation.Aivika.Trans hiding (ProcessId)

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event

-- | Send a message to the specified remote process with the current receive time.
sendMessage :: Serializable a => ProcessId -> a -> Event DIO ()
sendMessage pid a =
  do t <- liftDynamics time
     enqueueMessage pid t a 

-- | Send a message to the specified remote process with the given receive time.
enqueueMessage :: Serializable a => ProcessId -> Double -> a -> Event DIO ()
enqueueMessage = undefined

-- | Blocks the simulation waiting for a message of the specified type.
expectMessage :: Serializable a => Event DIO a
expectMessage = undefined

-- | Like 'expectMessage' but with a timeout.
expectMessageTimeout :: Serializable a => Int -> Event DIO (Maybe a)
expectMessageTimeout = undefined

-- | The signal triggered when the remote message of the specified type has come.
messageReceived :: Serializable a => Signal DIO a
messageReceived = undefined
