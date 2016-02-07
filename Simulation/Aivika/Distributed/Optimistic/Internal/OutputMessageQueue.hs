
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an output message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
       (OutputMessageQueue,
        newOutputMessageQueue,
        sendMessage,
        rollbackMessages,
        generateMessageSequenceNo) where

import Data.IORef

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Vector
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Event

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Specifies the output message queue.
data OutputMessageQueue =
  OutputMessageQueue { outputMessages :: Vector Message,
                       -- ^ The output messages.
                       outputMessageSequenceNo :: IORef Int
                       -- ^ The next sequence number.
                     }

-- | Create a new output message queue.
newOutputMessageQueue :: DIO OutputMessageQueue
newOutputMessageQueue =
  do ms <- liftIOUnsafe newVector
     rn <- liftIOUnsafe $ newIORef 0
     return OutputMessageQueue { outputMessages = ms,
                                 outputMessageSequenceNo = rn }

-- | Send the message.
sendMessage :: OutputMessageQueue -> Message -> DIO ()
sendMessage q m =
  do when (messageSendTime m > messageReceiveTime m) $
       error "The Send time cannot be greater than the Receive message time: sendMessage"
     when (messageAntiToggle m) $
       error "Cannot directly send the anti-message: sendMessage"
     n <- liftIOUnsafe $ vectorCount (outputMessages q)
     when (n > 0) $
       do m' <- liftIOUnsafe $ readVector (outputMessages q) (n - 1)
          when (messageSendTime m' > messageSendTime m) $
            error "A new output message comes from the past: sendMessage."
     deliverMessage m
     liftIOUnsafe $ appendVector (outputMessages q) m

-- | Rollback the messages till the specified time including that one.
rollbackMessages :: OutputMessageQueue -> Double -> DIO ()
rollbackMessages q t =
  do ms <- liftIOUnsafe $ extractMessagesToRollback q t
     forM_ ms (deliverAntiMessage . antiMessage)
                 
-- | Return the messages to roolback by the specified time.
extractMessagesToRollback :: OutputMessageQueue -> Double -> IO [Message]
extractMessagesToRollback q t =
  let loop i acc
        | i < 0     = return acc
        | otherwise =
          do m <- readVector (outputMessages q) i
             if messageSendTime m < t
               then return acc
               else do vectorDeleteAt (outputMessages q) i
                       loop (i - 1) (m : acc)
  in do n <- vectorCount (outputMessages q)
        loop (n - 1) []

-- | Generate a next message sequence number.
generateMessageSequenceNo :: OutputMessageQueue -> IO Int
generateMessageSequenceNo q =
  atomicModifyIORef (outputMessageSequenceNo q) $ \n ->
  let n' = n + 1 in n' `seq` (n', n)

-- | Deliver the message on low level.
deliverMessage :: Message -> DIO ()
deliverMessage x =
  liftDistributedUnsafe $
  DP.send (messageReceiverId x) x

-- | Deliver the anti-message on low level.
deliverAntiMessage :: Message -> DIO ()
deliverAntiMessage x =
  liftDistributedUnsafe $
  DP.send (messageReceiverId x) x
