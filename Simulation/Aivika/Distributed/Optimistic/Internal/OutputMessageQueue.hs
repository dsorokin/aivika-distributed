
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
  OutputMessageQueue { outputMessages :: Vector Message,
                       -- ^ The output messages.
                       outputMessageIndex :: IORef Int
                       -- ^ An index of the next actual item.
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
     r  <- liftIOUnsafe0 $ newIORef 0
     return OutputMessageQueue { outputMessages = ms,
                                 outputMessageIndex = r }

-- | Send the message.
sendMessage :: OutputMessageQueue -> Message -> Event DIO ()
sendMessage = undefined

-- | Rollback the messages till the specified time including that one.
rollbackMessages :: OutputMessageQueue -> Double -> Event DIO ()
rollbackMessages = undefined
