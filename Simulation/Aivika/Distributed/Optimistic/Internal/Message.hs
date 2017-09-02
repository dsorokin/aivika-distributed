
{-# LANGUAGE RankNTypes, DeriveGeneric, DeriveDataTypeable #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Message
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
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
        AcknowledgementMessage(..),
        acknowledgementMessage,
        LogicalProcessMessage(..),
        TimeServerMessage(..),
        InboxProcessMessage(..),
        KeepAliveMessage(..)) where

import GHC.Generics

import Data.Typeable
import Data.Binary

import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Serializable

import Simulation.Aivika.Distributed.Optimistic.State

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
data AcknowledgementMessage =
  AcknowledgementMessage { acknowledgementSequenceNo :: Int,
                           -- ^ The sequence number.
                           acknowledgementSendTime :: Double,
                           -- ^ The send time.
                           acknowledgementReceiveTime :: Double,
                           -- ^ The receive time.
                           acknowledgementSenderId :: DP.ProcessId,
                           -- ^ The sender of the source message.
                           acknowledgementReceiverId :: DP.ProcessId,
                           -- ^ The receiver of the source message.
                           acknowledgementAntiToggle :: Bool,
                           -- ^ Whether this is an anti-message acknowledgement.
                           acknowledgementMarked :: Bool
                           -- ^ Whether the acknowledgement is marked.
                         } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary AcknowledgementMessage

-- | Create an acknowledgement message specifying whether it will be marked.
acknowledgementMessage :: Bool -> Message -> AcknowledgementMessage
acknowledgementMessage marked x =
  AcknowledgementMessage { acknowledgementSequenceNo = messageSequenceNo x,
                           acknowledgementSendTime = messageSendTime x,
                           acknowledgementReceiveTime = messageReceiveTime x,
                           acknowledgementSenderId = messageSenderId x,
                           acknowledgementReceiverId = messageReceiverId x,
                           acknowledgementAntiToggle = messageAntiToggle x,
                           acknowledgementMarked = marked
                         }

-- | The message sent to the logical process.
data LogicalProcessMessage = QueueMessage Message
                             -- ^ the message has come from the remote process
                           | QueueMessageBulk [Message]
                             -- ^ a bulk of messages that have come from the remote process
                           | AcknowledgementQueueMessage AcknowledgementMessage
                             -- ^ the acknowledgement message has come from the remote process
                           | AcknowledgementQueueMessageBulk [AcknowledgementMessage]
                             -- ^ a bulk of acknowledgement messages that have come from the remote process
                           | ComputeLocalTimeMessage
                             -- ^ the time server requests for a local minimum time
                           | GlobalTimeMessage Double
                             -- ^ the time server sent a global time
                           | ProcessMonitorNotificationMessage DP.ProcessMonitorNotification
                             -- ^ the process monitor notification
                           | ReconnectProcessMessage DP.ProcessId
                             -- ^ finish reconnecting to the specified process
                           | ProvideLogicalProcessStateMessage DP.ProcessId
                             -- ^ provide the logical process state
                           | AbortSimulationMessage
                             -- ^ abort the simulation
                           deriving (Show, Typeable, Generic)

instance Binary LogicalProcessMessage

-- | The time server message.
data TimeServerMessage = RegisterLogicalProcessMessage DP.ProcessId
                         -- ^ register the logical process in the time server
                       | UnregisterLogicalProcessMessage DP.ProcessId
                         -- ^ unregister the logical process from the time server
                       | TerminateTimeServerMessage DP.ProcessId
                         -- ^ the logical process asked to terminate the time server
                       | ComputeLocalTimeAcknowledgementMessage DP.ProcessId
                         -- ^ the acknowledgement message after the server asked to compute the local time
                       | RequestGlobalTimeMessage DP.ProcessId
                         -- ^ the logical process requested for the global minimum time
                       | LocalTimeMessage DP.ProcessId Double
                         -- ^ the logical process sent its local minimum time
                       | ProvideTimeServerStateMessage DP.ProcessId
                         -- ^ send the time server monitoring state message
                       | ReMonitorTimeServerMessage [DP.ProcessId]
                         -- ^ re-monitor the logical processes by their identifiers
                       deriving (Eq, Show, Typeable, Generic)

instance Binary TimeServerMessage

-- | The message destined directly for the inbox process.
data InboxProcessMessage = MonitorProcessMessage DP.ProcessId
                           -- ^ monitor the logical process by its inbox process identifier
                         | ReMonitorProcessMessage [DP.ProcessId]
                           -- ^ re-monitor the logical processes by their identifiers
                         | TrySendKeepAliveMessage
                           -- ^ try to send a keep alive message
                         | SendQueueMessage DP.ProcessId Message
                           -- ^ send a queue message via the inbox process
                         | SendQueueMessageBulk DP.ProcessId [Message]
                           -- ^ send a bulk of queue messages via the inbox process
                         | SendAcknowledgementQueueMessage DP.ProcessId AcknowledgementMessage
                           -- ^ send an acknowledgement message via the inbox process
                         | SendAcknowledgementQueueMessageBulk DP.ProcessId [AcknowledgementMessage]
                           -- ^ send a bulk of acknowledgement messages via the inbox process
                         | SendLocalTimeMessage DP.ProcessId DP.ProcessId Double
                           -- ^ send the local time message to the time server
                         | SendRequestGlobalTimeMessage DP.ProcessId DP.ProcessId
                           -- ^ send the request for the global virtual time
                         | SendRegisterLogicalProcessMessage DP.ProcessId DP.ProcessId
                           -- ^ register the logical process in the time server
                         | SendUnregisterLogicalProcessMessage DP.ProcessId DP.ProcessId
                           -- ^ unregister the logical process from the time server
                         | SendTerminateTimeServerMessage DP.ProcessId DP.ProcessId
                           -- ^ the logical process asked to terminate the time server
                         | RegisterLogicalProcessAcknowledgementMessage DP.ProcessId
                           -- ^ after registering the logical process in the time server
                         | UnregisterLogicalProcessAcknowledgementMessage DP.ProcessId
                           -- ^ after unregistering the logical process from the time server
                         | TerminateTimeServerAcknowledgementMessage DP.ProcessId
                           -- ^ after started terminating the time server
                         | TerminateInboxProcessMessage
                           -- ^ terminate the inbox process
                         deriving (Eq, Show, Typeable, Generic)

instance Binary InboxProcessMessage

-- | The keep-alive message type.
data KeepAliveMessage = KeepAliveMessage
                        -- ^ the keel-alive message.
                        deriving (Eq, Show, Typeable, Generic)

instance Binary KeepAliveMessage
