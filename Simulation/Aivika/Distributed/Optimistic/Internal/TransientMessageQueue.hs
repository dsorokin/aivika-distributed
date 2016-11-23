
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TransientMessageQueue
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
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
        transientMessageQueueTime,
        enqueueTransientMessage,
        processAcknowledgmentMessage,
        clearAcknowledgmentMessages,
        deliverAcknowledgmentMessage,
        deliverAcknowledgmentMessages) where

import qualified Data.Set as S
import Data.List
import Data.IORef

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO

-- | Specifies the transient message queue.
data TransientMessageQueue =
  TransientMessageQueue { queuePrototypeMessages :: IORef (S.Set TransientMessageQueueItem),
                          -- ^ The prototype messages.
                          queueMarkedMessageTime :: IORef Double
                          -- ^ The marked acknowledgment message time.
                        }

-- | Represents an acknowledgement message representative.
data TransientMessageQueueItem =
  TransientMessageQueueItem { itemSequenceNo :: Int,
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
                              -- ^ Whether it was the anti-message acknowledgment.
                            } deriving (Eq, Show)

instance Ord TransientMessageQueueItem where

  x <= y =
    (itemReceiveTime x <= itemReceiveTime y) ||
    (itemSendTime x <= itemSendTime y) ||
    (itemSequenceNo x <= itemSequenceNo y) ||
    (itemReceiverId x <= itemReceiverId y) ||
    (itemSenderId x <= itemSenderId y) ||
    (itemAntiToggle x <= itemAntiToggle y)

-- | Return a queue item by the specified transient message.
transientMessageQueueItem :: Message -> TransientMessageQueueItem
transientMessageQueueItem m =
  TransientMessageQueueItem { itemSequenceNo  = messageSequenceNo m,
                              itemSendTime    = messageSendTime m,
                              itemReceiveTime = messageReceiveTime m,
                              itemSenderId    = messageSenderId m,
                              itemReceiverId  = messageReceiverId m,
                              itemAntiToggle  = messageAntiToggle m }

-- | Return a queue item by the specified acknowledgment message.
acknowledgmentMessageQueueItem :: AcknowledgmentMessage -> TransientMessageQueueItem
acknowledgmentMessageQueueItem m =
  TransientMessageQueueItem { itemSequenceNo  = acknowledgmentSequenceNo m,
                              itemSendTime    = acknowledgmentSendTime m,
                              itemReceiveTime = acknowledgmentReceiveTime m,
                              itemSenderId    = acknowledgmentSenderId m,
                              itemReceiverId  = acknowledgmentReceiverId m,
                              itemAntiToggle  = acknowledgmentAntiToggle m }

-- | Create a new transient message queue.
newTransientMessageQueue :: DIO TransientMessageQueue
newTransientMessageQueue =
  do ms <- liftIOUnsafe $ newIORef S.empty
     r  <- liftIOUnsafe $ newIORef (1 / 0)
     return TransientMessageQueue { queuePrototypeMessages = ms,
                                    queueMarkedMessageTime = r }

-- | Get the virtual time of the transient message queue.
transientMessageQueueTime :: TransientMessageQueue -> IO Double
transientMessageQueueTime q = liftM2 min m1 m2
  where m1 = do s <- readIORef (queuePrototypeMessages q)
                if S.null s
                  then return (1 / 0)
                  else let m = S.findMin s
                       in return (itemReceiveTime m)
        m2 = readIORef (queueMarkedMessageTime q)

-- | Enqueue the transient message.
enqueueTransientMessage :: TransientMessageQueue -> Message -> IO ()
enqueueTransientMessage q m =
  modifyIORef (queuePrototypeMessages q) $
  S.insert (transientMessageQueueItem m)

-- | Enqueue the acknowledgment message.
enqueueAcknowledgmentMessage :: TransientMessageQueue -> AcknowledgmentMessage -> IO ()
enqueueAcknowledgmentMessage q m =
  modifyIORef' (queueMarkedMessageTime q) $
  min (acknowledgmentReceiveTime m)

-- | Process the acknowledgment message.
processAcknowledgmentMessage :: TransientMessageQueue -> AcknowledgmentMessage -> IO () 
processAcknowledgmentMessage q m =
  do modifyIORef (queuePrototypeMessages q) $
       S.delete (acknowledgmentMessageQueueItem m)
     when (acknowledgmentMarked m) $
       enqueueAcknowledgmentMessage q m

-- | Clear the marked acknowledgment messages.
clearAcknowledgmentMessages :: TransientMessageQueue -> IO ()
clearAcknowledgmentMessages q =
  writeIORef (queueMarkedMessageTime q) (1 / 0)

-- | Deliver the acknowledgment message on low level.
deliverAcknowledgmentMessage :: AcknowledgmentMessage -> DIO ()
deliverAcknowledgmentMessage x =
  liftDistributedUnsafe $
  DP.send (acknowledgmentSenderId x) (AcknowledgmentQueueMessage x)

-- | Deliver the acknowledgment messages on low level.
deliverAcknowledgmentMessages :: [AcknowledgmentMessage] -> DIO ()
deliverAcknowledgmentMessages xs =
  let ys = groupBy (\a b -> acknowledgmentSenderId a == acknowledgmentSenderId b) xs
      dlv []         = return ()
      dlv zs@(z : _) =
        liftDistributedUnsafe $
        DP.send (acknowledgmentSenderId z) (AcknowledgmentQueueMessageBulk zs)
  in forM_ ys dlv
