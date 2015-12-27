
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

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

import Unsafe.Coerce

import Data.Binary
import qualified Data.ByteString as BBS
import qualified Data.ByteString.Lazy as LBS

import Control.Monad
import Control.Distributed.Process (ProcessId, getSelfPid)
import Control.Distributed.Process.Serializable

import Simulation.Aivika.Trans hiding (ProcessId)
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event
import qualified Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue as IMQ
import qualified Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue as OMQ

-- | Send a message to the specified remote process with the current receive time.
sendMessage :: forall a. Serializable a => ProcessId -> a -> Event DIO ()
sendMessage pid a =
  do t <- liftDynamics time
     enqueueMessage pid t a 

-- | Send a message to the specified remote process with the given receive time.
enqueueMessage :: forall a. Serializable a => ProcessId -> Double -> a -> Event DIO ()
enqueueMessage pid t a =
  Event $ \p ->
  let queue = queueOutputMessages $
              runEventQueue (pointRun p)
  in invokeEvent p $
     do sequenceNo <- OMQ.generateMessageSequenceNo queue
        let sendTime    = pointTime p
            receiveTime = t
        sender <- liftComp $ liftDIOUnsafe $ getSelfPid
        let receiver = pid
            antiToggle = False
            binaryData = LBS.toStrict $ encode a
            decodedData = unsafeCoerce a
            binaryFingerprint = encodeFingerprint decodedFingerprint
            decodedFingerprint = fingerprint a
            message = Message { messageSequenceNo = sequenceNo,
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
        OMQ.sendMessage queue message

-- | Blocks the simulation waiting for a message of the specified type.
expectMessage :: forall a. Serializable a => Event DIO a
expectMessage = undefined

-- | Like 'expectMessage' but with a timeout.
expectMessageTimeout :: forall a. Serializable a => Int -> Event DIO (Maybe a)
expectMessageTimeout = undefined

-- | The signal triggered when the remote message of the specified type has come.
messageReceived :: forall a. Serializable a => Signal DIO a
messageReceived =
  let f = fingerprint (undefined :: a)
  in Signal { handleSignal = \h ->
               Event $ \p ->
               let queue = queueInputMessages $
                           runEventQueue (pointRun p)
                   signal = IMQ.messageEnqueued queue
               in invokeEvent p $
                  handleSignal signal $ \x ->
                  when (f == messageDecodedFingerprint x) $
                  let decoded :: a
                      decoded = messageDecodedData x
                  in decoded `seq` h decoded
            }
                      
                        
  