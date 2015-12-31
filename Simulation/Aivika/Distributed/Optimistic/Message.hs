
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

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

import Data.Time
import Data.Binary
import qualified Data.ByteString as BBS
import qualified Data.ByteString.Lazy as LBS

import Control.Monad
import Control.Distributed.Process (ProcessId, getSelfPid)
import Control.Distributed.Process.Serializable

import Simulation.Aivika.Trans hiding (ProcessId)
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event
import qualified Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue as IMQ
import qualified Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue as OMQ
import Simulation.Aivika.Distributed.Optimistic.DIO
import Simulation.Aivika.Distributed.Optimistic.Ref.Base

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
        sender <- liftComp $ liftDistributedUnsafe $ getSelfPid
        let receiver = pid
            antiToggle = False
            binaryData = encode a
            decodedData :: forall b. Serializable b => b
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

-- | Blocks the simulation until the specified signal is triggered which
-- must depend directly or indirectly on the 'messageReceived' signal.
expectMessage :: Signal DIO a -> Process DIO a
expectMessage signal =
  do pid <- liftSimulation newProcessId
     spawnProcessUsingIdWith CancelChildAfterParent pid $
       let loop =
             do liftEvent expectInputMessage
                loop
       in loop
     processAwait $
       flip mapSignalM signal $ \a ->
       do cancelProcessWithId pid
          return a

-- | Like 'expectMessage' but with a timeout in milliseconds.
expectMessageTimeout :: Int -> Signal DIO a -> Process DIO (Maybe a)
expectMessageTimeout timeout signal =
  do t0   <- liftComp $ liftIOUnsafe getCurrentTime
     src  <- liftSimulation newSignalSource
     pid1 <- liftSimulation newProcessId
     pid2 <- liftSimulation newProcessId
     spawnProcessUsingIdWith CancelChildAfterParent pid1 $
       let loop dt =
             do liftEvent $ expectInputMessageTimeout dt
                when (dt > 0) $
                  do t1 <- liftComp $ liftIOUnsafe getCurrentTime
                     let dt' = timeout - truncate (1000 * diffUTCTime t1 t0)
                     if dt' > 0
                       then loop dt'
                       else return ()
       in do loop timeout
             liftEvent $
               do cancelProcessWithId pid2
                  triggerSignal src Nothing
     spawnProcessUsingIdWith CancelChildAfterParent pid2 $
       do a <- processAwait signal
          liftEvent $
            do cancelProcessWithId pid1
               triggerSignal src (Just a)
     processAwait (publishSignal src)
          
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
                      
                        
  
