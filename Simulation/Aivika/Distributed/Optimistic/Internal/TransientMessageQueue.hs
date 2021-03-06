
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TransientMessageQueue
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 8.0.1
--
-- This module defines a transient message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.TransientMessageQueue
       (TransientMessageQueue,
        newTransientMessageQueue,
        transientMessageQueueSize,
        transientMessageQueueTime,
        transientMessages,
        enqueueTransientMessage,
        processAcknowledgementMessage,
        acknowledgementMessageTime,
        resetAcknowledgementMessageTime,
        deliverAcknowledgementMessage,
        deliverAcknowledgementMessages,
        dequeueTransientMessages) where

import qualified Data.Map as M
import Data.List
import Data.IORef
import Data.Word

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO

-- | Specifies the transient message queue.
data TransientMessageQueue =
  TransientMessageQueue { queueTransientMessages :: IORef (M.Map TransientMessageQueueItem Message),
                          -- ^ The transient messages.
                          queueMarkedMessageTime :: IORef Double
                          -- ^ The marked acknowledgement message time.
                        }

-- | Represents an acknowledgement message representative.
data TransientMessageQueueItem =
  TransientMessageQueueItem { itemSequenceNo :: Word64,
                              -- ^ The sequence number.
                              itemSendTime :: Double,
                              -- ^ The send time.
                              itemReceiveTime :: Double,
                              -- ^ The receive time.
                              itemSenderId :: DP.ProcessId,
                              -- ^ The sender of the source message.
                              itemReceiverId :: DP.ProcessId,
                              -- ^ The receiver of the source message.
                              itemAntiToggle :: Bool
                              -- ^ Whether it was the anti-message acknowledgement.
                            } deriving (Eq, Show)

instance Ord TransientMessageQueueItem where

  x <= y
    | (itemReceiveTime x < itemReceiveTime y) = True
    | (itemReceiveTime x > itemReceiveTime y) = False
    | (itemSendTime x < itemSendTime y)       = True
    | (itemSendTime x > itemSendTime y)       = False
    | (itemSequenceNo x < itemSequenceNo y)   = True
    | (itemSequenceNo x > itemSequenceNo y)   = False
    | (itemReceiverId x < itemReceiverId y)   = True
    | (itemReceiverId x > itemReceiverId y)   = False
    | (itemSenderId x < itemSenderId y)       = True
    | (itemSenderId x > itemSenderId y)       = False
    | (itemAntiToggle x < itemAntiToggle y)   = True
    | (itemAntiToggle x > itemAntiToggle y)   = False
    | otherwise                               = True

-- | Return a queue item by the specified transient message.
transientMessageQueueItem :: Message -> TransientMessageQueueItem
transientMessageQueueItem m =
  TransientMessageQueueItem { itemSequenceNo  = messageSequenceNo m,
                              itemSendTime    = messageSendTime m,
                              itemReceiveTime = messageReceiveTime m,
                              itemSenderId    = messageSenderId m,
                              itemReceiverId  = messageReceiverId m,
                              itemAntiToggle  = messageAntiToggle m }

-- | Return a queue item by the specified acknowledgement message.
acknowledgementMessageQueueItem :: AcknowledgementMessage -> TransientMessageQueueItem
acknowledgementMessageQueueItem m =
  TransientMessageQueueItem { itemSequenceNo  = acknowledgementSequenceNo m,
                              itemSendTime    = acknowledgementSendTime m,
                              itemReceiveTime = acknowledgementReceiveTime m,
                              itemSenderId    = acknowledgementSenderId m,
                              itemReceiverId  = acknowledgementReceiverId m,
                              itemAntiToggle  = acknowledgementAntiToggle m }

-- | Create a new transient message queue.
newTransientMessageQueue :: DIO TransientMessageQueue
newTransientMessageQueue =
  do ms <- liftIOUnsafe $ newIORef M.empty
     r  <- liftIOUnsafe $ newIORef (1 / 0)
     return TransientMessageQueue { queueTransientMessages = ms,
                                    queueMarkedMessageTime = r }

-- | Get the transient message queue size.
transientMessageQueueSize :: TransientMessageQueue -> IO Int
{-# INLINE transientMessageQueueSize #-}
transientMessageQueueSize q =
  fmap M.size $ readIORef (queueTransientMessages q)

-- | Get the virtual time of the transient message queue.
transientMessageQueueTime :: TransientMessageQueue -> IO Double
transientMessageQueueTime q =
  do ms <- readIORef (queueTransientMessages q)
     if M.null ms
       then return (1 / 0)
       else let (m, _) = M.findMin ms
            in return (itemReceiveTime m)

-- | Get the transient messages.
transientMessages :: TransientMessageQueue -> IO [Message]
transientMessages q =
  do ms <- readIORef (queueTransientMessages q)
     return (M.elems ms)

-- | Enqueue the transient message.
enqueueTransientMessage :: TransientMessageQueue -> Message -> IO ()
enqueueTransientMessage q m =
  modifyIORef (queueTransientMessages q) $
  M.insert (transientMessageQueueItem m) m

-- | Enqueue the acknowledgement message.
enqueueAcknowledgementMessage :: TransientMessageQueue -> AcknowledgementMessage -> IO ()
enqueueAcknowledgementMessage q m =
  modifyIORef' (queueMarkedMessageTime q) $
  min (acknowledgementReceiveTime m)

-- | Process the acknowledgement message.
processAcknowledgementMessage :: TransientMessageQueue -> AcknowledgementMessage -> IO () 
processAcknowledgementMessage q m =
  do ms <- readIORef (queueTransientMessages q)
     let k = acknowledgementMessageQueueItem m
     when (M.member k ms) $
       do modifyIORef (queueTransientMessages q) $
            M.delete k
          when (acknowledgementMarked m) $
            enqueueAcknowledgementMessage q m

-- | Get the minimal marked acknowledgement message time.
acknowledgementMessageTime :: TransientMessageQueue -> IO Double
acknowledgementMessageTime q =
  readIORef (queueMarkedMessageTime q)

-- | Reset the marked acknowledgement message time.
resetAcknowledgementMessageTime :: TransientMessageQueue -> IO ()
resetAcknowledgementMessageTime q =
  writeIORef (queueMarkedMessageTime q) (1 / 0)

-- | Deliver the acknowledgement message on low level.
deliverAcknowledgementMessage :: AcknowledgementMessage -> DIO ()
deliverAcknowledgementMessage x =
  sendAcknowledgementMessageDIO (acknowledgementSenderId x) x

-- | Deliver the acknowledgement messages on low level.
deliverAcknowledgementMessages :: [AcknowledgementMessage] -> DIO ()
deliverAcknowledgementMessages xs =
  let ys = groupBy (\a b -> acknowledgementSenderId a == acknowledgementSenderId b) xs
      dlv []         = return ()
      dlv zs@(z : _) =
        sendAcknowledgementMessagesDIO (acknowledgementSenderId z) zs
  in forM_ ys dlv

-- | Dequeue the transient messages associated with the specified logical process.
dequeueTransientMessages :: TransientMessageQueue -> DP.ProcessId -> IO ()
dequeueTransientMessages q pid =
  modifyIORef (queueTransientMessages q) $
  M.filter (\m -> messageReceiverId m /= pid)
