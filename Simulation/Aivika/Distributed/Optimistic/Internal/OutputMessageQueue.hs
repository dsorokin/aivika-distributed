
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
        rollbackOutputMessages,
        reduceOutputMessages,
        generateMessageSequenceNo) where

import Data.IORef

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import qualified Simulation.Aivika.DoubleLinkedList as DLL

import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Event

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Specifies the output message queue.
data OutputMessageQueue =
  OutputMessageQueue { outputMessages :: DLL.DoubleLinkedList Message,
                       -- ^ The output messages.
                       outputMessageSequenceNo :: IORef Int
                       -- ^ The next sequence number.
                     }

-- | Create a new output message queue.
newOutputMessageQueue :: DIO OutputMessageQueue
newOutputMessageQueue =
  do ms <- liftIOUnsafe DLL.newList
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
     f <- liftIOUnsafe $ DLL.listNull (outputMessages q)
     unless f $
       do m' <- liftIOUnsafe $ DLL.listLast (outputMessages q)
          when (messageSendTime m' > messageSendTime m) $
            error "A new output message comes from the past: sendMessage."
     deliverMessage m
     liftIOUnsafe $ DLL.listAddLast (outputMessages q) m

-- | Rollback the messages till the specified time including that one.
rollbackOutputMessages :: OutputMessageQueue -> Double -> DIO ()
rollbackOutputMessages q t =
  do ms <- liftIOUnsafe $ extractMessagesToRollback q t
     forM_ ms (deliverAntiMessage . antiMessage)
                 
-- | Return the messages to roolback by the specified time.
extractMessagesToRollback :: OutputMessageQueue -> Double -> IO [Message]
extractMessagesToRollback q t = loop []
  where
    loop acc =
      do f <- DLL.listNull (outputMessages q)
         if f
           then return acc
           else do m <- DLL.listLast (outputMessages q)
                   if messageSendTime m < t
                     then return acc
                     else do DLL.listRemoveLast (outputMessages q)
                             loop (m : acc)

-- | Reduce the output messages till the specified time.
reduceOutputMessages :: OutputMessageQueue -> Double -> IO ()
reduceOutputMessages q t = loop
  where
    loop =
      do f <- DLL.listNull (outputMessages q)
         unless f $
           do m <- DLL.listFirst (outputMessages q)
              when (messageSendTime m < t) $
                do DLL.listRemoveFirst (outputMessages q)
                   loop

-- | Generate a next message sequence number.
generateMessageSequenceNo :: OutputMessageQueue -> IO Int
generateMessageSequenceNo q =
  atomicModifyIORef (outputMessageSequenceNo q) $ \n ->
  let n' = n + 1 in n' `seq` (n', n)

-- | Deliver the message on low level.
deliverMessage :: Message -> DIO ()
deliverMessage x =
  liftDistributedUnsafe $
  DP.send (messageReceiverId x) (QueueMessage x)

-- | Deliver the anti-message on low level.
deliverAntiMessage :: Message -> DIO ()
deliverAntiMessage x =
  liftDistributedUnsafe $
  DP.send (messageReceiverId x) (QueueMessage x)
