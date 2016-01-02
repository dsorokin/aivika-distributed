
{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines the Time Server that coordinates the global simulation time.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
       (TimeServer,
        GlobalTimeMessage(..),
        GlobalTimeMessageResp(..),
        LocalTimeMessage(..),
        LocalTimeMessageResp(..)) where

import GHC.Generics

import Data.Typeable
import Data.Binary

-- | The Time Server that coordinates the global simulation time.
data TimeServer = TimeServer

-- | A message that is sent by the Time Server for informing about the global simulation time.
data GlobalTimeMessage =
  GlobalTimeMessage { globalTimeValue :: Double
                      -- ^ the global time value
                    } deriving (Eq, Ord, Show, Typeable, Generic)

-- | A message that is received by the Time Server after informing about the global simulation time.
data GlobalTimeMessageResp =
  GlobalTimeMessageResp { globalTimeResValue :: Double
                          -- ^ the local time value sent in response
                        } deriving (Eq, Ord, Show, Typeable, Generic)

-- | A message that is sent to the Time Server for informing it about the local simulation time.
data LocalTimeMessage =
  LocalTimeMessage { localTimeValue :: Double
                     -- ^ the local time value
                   } deriving (Eq, Ord, Show, Typeable, Generic)

-- | A message that is received from the Time Server after informing it about the local simulation time.
data LocalTimeMessageResp =
  LocalTimeMessageResp { localTimeRespValue :: Double
                         -- ^ the global time value sent in response
                       } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary GlobalTimeMessage
instance Binary GlobalTimeMessageResp

instance Binary LocalTimeMessage
instance Binary LocalTimeMessageResp
