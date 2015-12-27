
{-# LANGUAGE RankNTypes #-}

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

import qualified Data.ByteString as BBS
import qualified Data.ByteString.Lazy as LBS
import Data.Typeable
import Data.Binary

import Control.Distributed.Process (ProcessId, send)
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
            messageBinaryData :: LBS.ByteString,
            -- ^ The message binary data.
            messageDecodedData :: forall a. Serializable a => a,
            -- ^ The decoded message data.
            messageBinaryFingerprint :: BBS.ByteString,
            -- ^ The message binary fingerprint of the data type.
            messageDecodedFingerprint :: Fingerprint
            -- ^ The decoded message fingerprint of the data type.
          } deriving (Typeable)

instance Binary Message where

  put x =
    do put (messageSequenceNo x)
       put (messageSendTime x)
       put (messageReceiveTime x)
       put (messageSender x)
       put (messageReceiver x)
       put (messageAntiToggle x)
       put (messageBinaryData x)
       put (messageBinaryFingerprint x)
  
  get =
    do sequenceNo <- get
       sendTime <- get
       receiveTime <- get
       sender <- get
       receiver <- get
       antiToggle <- get
       binaryData <- get
       binaryFingerprint <- get
       let decodedData :: forall a. Serializable a => a
           decodedData = decode binaryData
           decodedFingerprint = decodeFingerprint binaryFingerprint
       return Message { messageSequenceNo = sequenceNo,
                        messageSendTime = sendTime,
                        messageReceiveTime = receiveTime,
                        messageSender = sender,
                        messageReceiver = receiver,
                        messageAntiToggle = antiToggle,
                        messageBinaryData = binaryData,
                        messageDecodedData = decodedData,
                        messageBinaryFingerprint = binaryFingerprint,
                        messageDecodedFingerprint = decodedFingerprint
                      }

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
  (messageBinaryFingerprint x == messageBinaryFingerprint y) &&
  (messageBinaryData x == messageBinaryData y)

instance Eq Message where

  x == y =
    (messageSequenceNo x == messageSequenceNo y) &&
    (messageSendTime x == messageSendTime y) &&
    (messageReceiveTime x == messageReceiveTime y) &&
    (messageSender x == messageSender y) &&
    (messageReceiver x == messageReceiver y) &&
    (messageAntiToggle x == messageAntiToggle y) &&
    (messageBinaryFingerprint x == messageBinaryFingerprint y) &&
    (messageBinaryData x == messageBinaryData y)

-- | Deliver the message on low level.
deliverMessage :: Message -> DIO ()
deliverMessage x =
  liftDIOUnsafe $
  send (messageReceiver x) x

-- | Similar to 'deliverMessage' but has a timeout whithin which
-- the delivery can be repeated in case of failure as we have
-- to deliver the anti-message as soon as possible.
deliverAntiMessage :: Message -> DIO ()
deliverAntiMessage x =
  liftDIOUnsafe $
  send (messageReceiver x) x
