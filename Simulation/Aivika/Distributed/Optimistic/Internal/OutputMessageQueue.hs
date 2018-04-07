
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
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
        outputMessageQueueSize,
        sendMessage,
        rollbackOutputMessages,
        reduceOutputMessages,
        generateMessageSequenceNo) where

import Data.List
import Data.IORef
import Data.Word

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
  OutputMessageQueue { outputEnqueueTransientMessage :: Message -> IO (),
                       -- ^ Enqueue the transient message.
                       outputMessages :: DLL.DoubleLinkedList Message,
                       -- ^ The output messages.
                       outputMessageSequenceNo :: IORef Word64
                       -- ^ The next sequence number.
                     }

-- | Create a new output message queue.
newOutputMessageQueue :: (Message -> IO ()) -> DIO OutputMessageQueue
newOutputMessageQueue transient =
  do ms <- liftIOUnsafe DLL.newList
     rn <- liftIOUnsafe $ newIORef 0
     return OutputMessageQueue { outputEnqueueTransientMessage = transient,
                                 outputMessages = ms,
                                 outputMessageSequenceNo = rn }

-- | Return the output message queue size.
outputMessageQueueSize :: OutputMessageQueue -> IO Int
outputMessageQueueSize = DLL.listCount . outputMessages

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
     liftIOUnsafe $ outputEnqueueTransientMessage q m
     deliverMessage m
     liftIOUnsafe $ DLL.listAddLast (outputMessages q) m

-- | Rollback the messages till the specified time either including that one or not.
rollbackOutputMessages :: OutputMessageQueue -> Double -> Bool -> DIO ()
rollbackOutputMessages q t including =
  do ms <- liftIOUnsafe $ extractMessagesToRollback q t including
     let ms' = map antiMessage ms
     liftIOUnsafe $
       forM_ ms' $ outputEnqueueTransientMessage q
     deliverAntiMessages ms'
     -- forM_ ms' deliverAntiMessage
                 
-- | Return the messages to roolback by the specified time.
extractMessagesToRollback :: OutputMessageQueue -> Double -> Bool -> IO [Message]
extractMessagesToRollback q t including = loop []
  where
    loop acc =
      do f <- DLL.listNull (outputMessages q)
         if f
           then return acc
           else do m <- DLL.listLast (outputMessages q)
                   if (not including) && (messageSendTime m == t)
                     then return acc
                     else if messageSendTime m < t
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
generateMessageSequenceNo :: OutputMessageQueue -> IO Word64
generateMessageSequenceNo q =
  atomicModifyIORef (outputMessageSequenceNo q) $ \n ->
  let n' = n + 1 in n' `seq` (n', n)

-- | Deliver the message on low level.
deliverMessage :: Message -> DIO ()
deliverMessage x =
  sendMessageDIO (messageReceiverId x) x

-- | Deliver the anti-message on low level.
deliverAntiMessage :: Message -> DIO ()
deliverAntiMessage x =
  sendMessageDIO (messageReceiverId x) x

-- | Deliver the anti-messages on low level.
deliverAntiMessages :: [Message] -> DIO ()
deliverAntiMessages xs =
  let ys = groupBy (\a b -> messageReceiverId a == messageReceiverId b) xs
      dlv []         = return ()
      dlv zs@(z : _) =
        sendMessagesDIO (messageReceiverId z) zs
  in forM_ ys dlv
