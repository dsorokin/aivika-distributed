
{-# LANGUAGE RankNTypes, DeriveGeneric #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Message
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines a message.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Message
       (Message(..),
        antiMessage,
        antiMessages,
        LocalProcessMessage(..),
        TimeServerMessage(..)) where

import GHC.Generics

import Data.Typeable
import Data.Binary

import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Serializable

-- | Represents a message.
data Message =
  Message { messageSequenceNo :: Int,
            -- ^ The sequence number.
            messageSendTime :: Double,
            -- ^ The send time.
            messageReceiveTime :: Double,
            -- ^ The receive time.
            messageSenderId :: DP.ProcessId,
            -- ^ The sender of the message.
            messageReceiverId :: DP.ProcessId,
            -- ^ The receiver of the message.
            messageAntiToggle :: Bool,
            -- ^ Whether this is an anti-message.
            messageData :: DP.Message
            -- ^ The message data.
          } deriving (Show, Typeable, Generic)

instance Binary Message

-- | Return an anti-message.
antiMessage :: Message -> Message
antiMessage x = x { messageAntiToggle = not (messageAntiToggle x) }

-- | Whether two messages are anti-messages.
antiMessages :: Message -> Message -> Bool
antiMessages x y =
  (messageSequenceNo x == messageSequenceNo y) &&
  (messageSendTime x == messageSendTime y) &&
  (messageReceiveTime x == messageReceiveTime y) &&
  (messageSenderId x == messageSenderId y) &&
  (messageReceiverId x == messageReceiverId y) &&
  (messageAntiToggle x /= messageAntiToggle y)

instance Eq Message where

  x == y =
    (messageSequenceNo x == messageSequenceNo y) &&
    (messageSendTime x == messageSendTime y) &&
    (messageReceiveTime x == messageReceiveTime y) &&
    (messageSenderId x == messageSenderId y) &&
    (messageReceiverId x == messageReceiverId y) &&
    (messageAntiToggle x == messageAntiToggle y)

-- | The message sent to the local process.
data LocalProcessMessage = QueueMessage Message
                            -- ^ the message has come from the remote process
                          | GlobalTimeMessage (Maybe Double)
                            -- ^ the time server sent a global time
                          | LocalTimeMessageResp Double
                            -- ^ the time server replied to 'LocalTimeMessage' sending its global time in response
                          | TerminateLocalProcessMessage
                            -- ^ the time server asked to terminate the process
                          deriving (Eq, Show, Typeable, Generic)

instance Binary LocalProcessMessage

-- | The time server message.
data TimeServerMessage = RegisterLocalProcessMessage DP.ProcessId
                         -- ^ register the local process in the time server
                       | UnregisterLocalProcessMessage DP.ProcessId
                         -- ^ unregister the local process from the time server
                       | GlobalTimeMessageResp DP.ProcessId Double
                         -- ^ the local process replied to 'GlobalTimeMessage' sending its local time in response
                       | LocalTimeMessage DP.ProcessId Double
                         -- ^ the local process sent its local time
                       | TerminateTimeServerMessage DP.ProcessId
                         -- ^ the local process asked to terminate the time server
                       deriving (Eq, Show, Typeable, Generic)

instance Binary TimeServerMessage

