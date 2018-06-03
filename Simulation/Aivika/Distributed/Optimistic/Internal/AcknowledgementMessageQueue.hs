
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.AcknowledgementMessageQueue
-- Copyright  : Copyright (c) 2015-2018, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an acknowledegment message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.AcknowledgementMessageQueue
       (AcknowledgementMessageQueue,
        newAcknowledgementMessageQueue,
        acknowledgementMessageQueueSize,
        enqueueAcknowledgementMessage,
        reduceAcknowledgementMessages,
        filterAcknowledgementMessages) where

import Data.Maybe
import Data.List
import Data.IORef

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Vector
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Dynamics
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Specifies the acknowledgement message queue.
data AcknowledgementMessageQueue =
  AcknowledgementMessageQueue { acknowledgementMessages :: Vector AcknowledgementMessage
                                -- ^ the acknowedgement messages
                              }

-- | Create a new acknowledgement message queue.
newAcknowledgementMessageQueue :: DIO AcknowledgementMessageQueue
newAcknowledgementMessageQueue =
  do ms <- liftIOUnsafe newVector
     return AcknowledgementMessageQueue { acknowledgementMessages = ms }

-- | Return the acknowledgement message queue size.
acknowledgementMessageQueueSize :: AcknowledgementMessageQueue -> IO Int
{-# INLINE acknowledgementMessageQueueSize #-}
acknowledgementMessageQueueSize = vectorCount . acknowledgementMessages

-- | Return a complement.
complement :: Int -> Int
complement x = - x - 1

-- | Enqueue a new acknowledement message ignoring the duplicated messages.
enqueueAcknowledgementMessage :: AcknowledgementMessageQueue -> AcknowledgementMessage -> IO ()
enqueueAcknowledgementMessage q m =
  do i <- lookupAcknowledgementMessageIndex q m
     when (i < 0) $
       do -- insert the message at the specified index
          let i' = complement i
          vectorInsert (acknowledgementMessages q) i' m

-- | Search for the message index.
lookupAcknowledgementMessageIndex' :: AcknowledgementMessageQueue -> AcknowledgementMessage -> Int -> Int -> IO Int
lookupAcknowledgementMessageIndex' q m left right =
  if left > right
  then return $ complement left
  else  
    do let index = (left + right) `div` 2
       m' <- readVector (acknowledgementMessages q) index
       let t' = acknowledgementReceiveTime m'
           t  = acknowledgementReceiveTime m
       if t' > t || (t' == t && m' > m)
         then lookupAcknowledgementMessageIndex' q m left (index - 1)
         else if t' < t || (t' == t && m' < m)
              then lookupAcknowledgementMessageIndex' q m (index + 1) right
              else return index      
 
-- | Search for the message index.
lookupAcknowledgementMessageIndex :: AcknowledgementMessageQueue -> AcknowledgementMessage -> IO Int
lookupAcknowledgementMessageIndex q m =
  do n <- vectorCount (acknowledgementMessages q)
     lookupAcknowledgementMessageIndex' q m 0 (n - 1)

-- | Reduce the acknowledgement messages till the specified time.
reduceAcknowledgementMessages :: AcknowledgementMessageQueue -> Double -> IO ()
reduceAcknowledgementMessages q t =
  do count <- vectorCount (acknowledgementMessages q)
     len   <- loop count 0
     when (len > 0) $
       vectorDeleteRange (acknowledgementMessages q) 0 len
       where
         loop n i
           | i >= n    = return i
           | otherwise = do m <- readVector (acknowledgementMessages q) i
                            if acknowledgementReceiveTime m < t
                              then loop n (i + 1)
                              else return i

-- | Filter the acknowledgement messages using the specified predicate.
filterAcknowledgementMessages :: (AcknowledgementMessage -> Bool) -> AcknowledgementMessageQueue -> IO [AcknowledgementMessage]
filterAcknowledgementMessages pred q =
  do count <- vectorCount (acknowledgementMessages q)
     loop count 0 []
       where
         loop n i acc
           | i >= n    = return (reverse acc)
           | otherwise = do m <- readVector (acknowledgementMessages q) i
                            if pred m
                              then loop n (i + 1) (m : acc)
                              else loop n (i + 1) acc
