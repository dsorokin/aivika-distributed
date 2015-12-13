
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines the Time Server that coordinates the global simulation time.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
       (TimeServer,
        GlobalTimeMessage,
        GlobalTimeMessageResp,
        LocalTimeMessage,
        LocalTimeMessageResp) where

-- | The Time Server that coordinates the global simulation time.
data TimeServer = TimeServer

-- | A message that is sent by the Time Server for informing about the global simulation time.
data GlobalTimeMessage = GlobalTimeMessage

-- | A message that is received by the Time Server after informing about the global simulation time.
data GlobalTimeMessageResp = GlobalTimeMessageResp

-- | A message that is sent to the Time Server for informing it about the local simulation time.
data LocalTimeMessage = LocalTimeMessage

-- | A message that is received from the Time Server after informing it about the local simulation time.
data LocalTimeMessageResp = LocalTimeMessageResp
