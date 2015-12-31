
{-# LANGUAGE RankNTypes, DeriveGeneric #-}

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
        deliverMessage,
        deliverAntiMessage) where

import GHC.Generics

import Data.Typeable
import Data.Binary

import qualified Control.Distributed.Process as DP
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
            messageSender :: DP.ProcessId,
            -- ^ The sender of the message.
            messageReceiver :: DP.ProcessId,
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
  (messageSender x == messageSender y) &&
  (messageReceiver x == messageReceiver y) &&
  (messageAntiToggle x /= messageAntiToggle y)

instance Eq Message where

  x == y =
    (messageSequenceNo x == messageSequenceNo y) &&
    (messageSendTime x == messageSendTime y) &&
    (messageReceiveTime x == messageReceiveTime y) &&
    (messageSender x == messageSender y) &&
    (messageReceiver x == messageReceiver y) &&
    (messageAntiToggle x == messageAntiToggle y)

-- | Deliver the message on low level.
deliverMessage :: Message -> DIO ()
deliverMessage x =
  liftDistributedUnsafe $
  DP.send (messageReceiver x) x

-- | Similar to 'deliverMessage' but has a timeout whithin which
-- the delivery can be repeated in case of failure as we have
-- to deliver the anti-message as soon as possible.
deliverAntiMessage :: Message -> DIO ()
deliverAntiMessage x =
  liftDistributedUnsafe $
  DP.send (messageReceiver x) x
