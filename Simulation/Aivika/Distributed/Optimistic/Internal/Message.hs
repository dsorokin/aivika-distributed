
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Message
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
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
        deliverMessage) where

import Data.ByteString

import Control.Distributed.Process (ProcessId)
import Control.Distributed.Process.Serializable

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

-- | Represents a message.
data Message =
  Message { messageSequenceNo :: Int,
            -- ^ The sequence number.
            messageSendTime :: Double,
            -- ^ The send time.
            messageReceiveTime :: Double,
            -- ^ The receive time.
            messageSender :: ProcessId,
            -- ^ The sender of the message.
            messageReceiver :: ProcessId,
            -- ^ The receiver of the message.
            messageAntiToggle :: Bool,
            -- ^ Whether this is an anti-message.
            messageData :: ByteString
            -- ^ The message data.
          } deriving (Eq, Ord, Show)

-- | Return an anti-message.
antiMessage :: Message -> Message
antiMessage x = x { messageAntiToggle = not (messageAntiToggle x) }

-- | Whether two messages are anti-messages.
antiMessages :: Message -> Message -> Bool
antiMessages x y =
  (messageSequenceNo x == messageSequenceNo y) &&
  (messageSendTime x == messageSendTime y) &&
  (messageReceiveTime x == messageReceiveTime y) &&
  (messageSender x == messageSender y) &&
  (messageReceiver x == messageReceiver y) &&
  (messageAntiToggle x /= messageAntiToggle y) &&
  (messageData x == messageData y)

-- | Deliver the message on low level.
deliverMessage :: Message -> DIO ()
deliverMessage = undefined
