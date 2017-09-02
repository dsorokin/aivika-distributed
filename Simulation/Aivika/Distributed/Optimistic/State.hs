
{-# LANGUAGE DeriveGeneric, DeriveDataTypeable #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.State
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines the monitoring states.
--
module Simulation.Aivika.Distributed.Optimistic.State
       (LogicalProcessState(..),
        TimeServerState(..)) where

import GHC.Generics

import Data.Typeable
import Data.Binary

import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Serializable

-- | Represents the state of the logical process.
data LogicalProcessState =
  LogicalProcessState { lpStateId :: DP.ProcessId,
                        -- ^ the process identifier
                        lpStateName :: String,
                        -- ^ the process name
                        lpStateStartTime :: Double,
                        -- ^ the start time
                        lpStateStopTime :: Double,
                        -- ^ the stop time
                        lpStateLocalTime :: Double,
                        -- ^ the local time of the process
                        lpStateEventQueueTime :: Double,
                        -- ^ the event queue time of the process
                        lpStateEventQueueSize :: Int,
                        -- ^ the event queue size
                        lpStateLogSize :: Int,
                        -- ^ the log size of the process
                        lpStateInputMessageCount :: Int,
                        -- ^ the count of the input messages
                        lpStateOutputMessageCount :: Int,
                        -- ^ the count of the output messages
                        lpStateTransientMessageCount :: Int,
                        -- ^ the count of the transient messages that did not receive an acknowledgement
                        lpStateRollbackCount :: Int
                        -- ^ the count of rollbacks
                      } deriving (Eq, Show, Typeable, Generic)

instance Binary LogicalProcessState

-- | Represents the state of the time server.
data TimeServerState =
  TimeServerState { tsStateId :: DP.ProcessId,
                    -- ^ the process identifier
                    tsStateName :: String,
                    -- ^ the time server name
                    tsStateGlobalVirtualTime :: Maybe Double,
                    -- ^ the global virtual time
                    tsStateLogicalProcesses :: [DP.ProcessId]
                    -- ^ the registered logical process identifiers
                  } deriving (Eq, Show, Typeable, Generic)

instance Binary TimeServerState
