
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an output message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.OutputMessageQueue
       (OutputMessageQueue,
        createOutputMessageQueue,
        sendMessage,
        rollbackMessages) where

import Data.IORef

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Vector
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Event

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Specifies the output message queue.
data OutputMessageQueue =
  OutputMessageQueue { outputMessages :: Vector Message
                       -- ^ The output messages.
                     }

-- | Lift the 'IO' computation in an unsafe manner.
liftIOUnsafe0 :: IO a -> Simulation DIO a
liftIOUnsafe0 = liftComp . DIO . liftIO

-- | Lift the 'IO' computation in an unsafe manner.
liftIOUnsafe :: IO a -> Event DIO a
liftIOUnsafe = liftComp . DIO . liftIO

-- | Create a new output message queue.
createOutputMessageQueue :: Simulation DIO OutputMessageQueue
createOutputMessageQueue =
  do ms <- liftIOUnsafe0 newVector
     return OutputMessageQueue { outputMessages = ms }

-- | Send the message.
sendMessage :: OutputMessageQueue -> Message -> Event DIO ()
sendMessage q m =
  do when (messageSendTime m > messageReceiveTime m) $
       error "The Send time cannot be greater than the Receive message time: sendMessage"
     n <- liftIOUnsafe $ vectorCount (outputMessages q)
     when (n > 0) $
       do m' <- liftIOUnsafe $ readVector (outputMessages q) (n - 1)
          when (messageSendTime m' > messageSendTime m) $
            error "A new output message comes from the past: sendMessage."
     liftIOUnsafe $ appendVector (outputMessages q) m
     doSendMessage q m

-- | Rollback the messages till the specified time including that one.
rollbackMessages :: OutputMessageQueue -> Double -> Event DIO ()
rollbackMessages q t =
  do ms <- extractMessagesToRollback q t
     forM_ ms (doSendMessage q . antiMessage)
                 
-- | Return the messages to roolback by the specified time.
extractMessagesToRollback :: OutputMessageQueue -> Double -> Event DIO [Message]
extractMessagesToRollback q t =
  let loop i acc
        | i < 0     = return acc
        | otherwise =
          do m <- liftIOUnsafe $ readVector (outputMessages q) i
             if messageSendTime m < t
               then return acc
               else do liftIOUnsafe $ vectorDeleteAt (outputMessages q) i
                       loop (i - 1) (m : acc)
  in do n <- liftIOUnsafe $ vectorCount (outputMessages q)
        loop (n - 1) []
                 
-- | Do send a message on low level.
doSendMessage :: OutputMessageQueue -> Message -> Event DIO ()
doSendMessage = undefined
