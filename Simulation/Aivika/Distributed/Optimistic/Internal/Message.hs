
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
        AcknowledgmentMessage(..),
        acknowledgmentMessage,
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

-- | Represents an acknowledgement message.
data AcknowledgmentMessage =
  AcknowledgmentMessage { acknowledgmentSequenceNo :: Int,
                          -- ^ The sequence number.
                          acknowledgmentSendTime :: Double,
                          -- ^ The send time.
                          acknowledgmentReceiveTime :: Double,
                          -- ^ The receive time.
                          acknowledgmentSenderId :: DP.ProcessId,
                          -- ^ The sender of the source message.
                          acknowledgmentReceiverId :: DP.ProcessId,
                          -- ^ The receiver of the source message.
                          acknowledgmentAntiToggle :: Bool,
                          -- ^ Whether this is an anti-message acknowledgment.
                          acknowledgmentMarked :: Bool
                          -- ^ Whether the acknowledgment is marked.
                        } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary AcknowledgmentMessage

-- | Create an acknowledgment message specifying whether it will be marked.
acknowledgmentMessage :: Bool -> Message -> AcknowledgmentMessage
acknowledgmentMessage marked x =
  AcknowledgmentMessage { acknowledgmentSequenceNo = messageSequenceNo x,
                          acknowledgmentSendTime = messageSendTime x,
                          acknowledgmentReceiveTime = messageReceiveTime x,
                          acknowledgmentSenderId = messageSenderId x,
                          acknowledgmentReceiverId = messageReceiverId x,
                          acknowledgmentAntiToggle = messageAntiToggle x,
                          acknowledgmentMarked = marked
                        }

-- | The message sent to the local process.
data LocalProcessMessage = QueueMessage Message
                           -- ^ the message has come from the remote process
                         | QueueMessageBulk [Message]
                           -- ^ a bulk of messages that have come from the remote process
                         | AcknowledgmentQueueMessage AcknowledgmentMessage
                           -- ^ the acknowledgment message has come from the remote process
                         | AcknowledgmentQueueMessageBulk [AcknowledgmentMessage]
                           -- ^ a bulk of acknowledgment messages that have come from the remote process
                         | ComputeLocalTimeMessage
                           -- ^ the time server requests for a local minimum time
                         | GlobalTimeMessage Double
                           -- ^ the time server sent a global time
                         | TerminateLocalProcessMessage
                           -- ^ the time server asked to terminate the process
                         deriving (Eq, Show, Typeable, Generic)

instance Binary LocalProcessMessage

-- | The time server message.
data TimeServerMessage = RegisterLocalProcessMessage DP.ProcessId
                         -- ^ register the local process in the time server
                       | UnregisterLocalProcessMessage DP.ProcessId
                         -- ^ unregister the local process from the time server
                       | RequestGlobalTimeMessage DP.ProcessId
                         -- ^ the local process requested for the global minimum time
                       | LocalTimeMessage DP.ProcessId Double
                         -- ^ the local process sent its local minimum time
                       | TerminateTimeServerMessage DP.ProcessId
                         -- ^ the local process asked to terminate the time server
                       deriving (Eq, Show, Typeable, Generic)

instance Binary TimeServerMessage

