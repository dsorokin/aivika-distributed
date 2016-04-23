
{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.DIO
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines a distributed computation based on 'IO'.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.DIO
       (DIO(..),
        DIOParams(..),
        invokeDIO,
        runDIO,
        defaultDIOParams,
        terminateDIO,
        unregisterDIO,
        dioParams,
        messageChannel,
        messageInboxId,
        timeServerId,
        logDIO,
        liftDistributedUnsafe) where

import Data.Typeable
import Data.Binary

import GHC.Generics

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Exception (throw)
import Control.Monad.Catch as C
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Trans.Exception
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Channel
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
import Simulation.Aivika.Distributed.Optimistic.Internal.Priority

-- | The parameters for the 'DIO' computation.
data DIOParams =
  DIOParams { dioLoggingPriority :: Priority,
              -- ^ The logging priority
              dioUndoableLogSizeThreshold :: Int,
              -- ^ The undoable log size threshold used for detecting an overflow
              dioOutputMessageQueueSizeThreshold :: Int,
              -- ^ The output message queue size threshold used for detecting an overflow
              dioSyncTimeout :: Int,
              -- ^ The timeout in microseconds used for synchronising the operations.
              dioAllowPrematureIO :: Bool,
              -- ^ Whether to allow performing the premature IO action; otherwise, raise an error
              dioAllowProcessingOutdatedMessage :: Bool
              -- ^ Whether to allow processing an outdated message with the receive time less than the global time
            } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary DIOParams

-- | The distributed computation based on 'IO'.
newtype DIO a = DIO { unDIO :: DIOContext -> DP.Process a
                      -- ^ Unwrap the computation.
                    }

-- | The context of the 'DIO' computation.
data DIOContext =
  DIOContext { dioChannel :: Channel LocalProcessMessage,
               -- ^ The channel of messages.
               dioInboxId :: DP.ProcessId,
               -- ^ The inbox process identifier.
               dioTimeServerId :: DP.ProcessId,
               -- ^ The time server process
               dioParams0 :: DIOParams
               -- ^ The parameters of the computation.
             }

instance Monad DIO where

  {-# INLINE return #-}
  return = DIO . const . return

  {-# INLINE (>>=) #-}
  (DIO m) >>= k = DIO $ \ps ->
    m ps >>= \a ->
    let m' = unDIO (k a) in m' ps

instance Applicative DIO where

  {-# INLINE pure #-}
  pure = return

  {-# INLINE (<*>) #-}
  (<*>) = ap

instance Functor DIO where

  {-# INLINE fmap #-}
  fmap f (DIO m) = DIO $ fmap f . m 

instance MonadException DIO where

  catchComp (DIO m) h = DIO $ \ps ->
    C.catch (m ps) (\e -> unDIO (h e) ps)

  finallyComp (DIO m1) (DIO m2) = DIO $ \ps ->
    C.finally (m1 ps) (m2 ps)
  
  throwComp e = DIO $ \ps ->
    throw e

-- | Invoke the 'DIO' computation.
invokeDIO :: DIOContext -> DIO a -> DP.Process a
{-# INLINE invokeDIO #-}
invokeDIO ps (DIO m) = m ps

-- | Lift the distributed 'Process' computation.
liftDistributedUnsafe :: DP.Process a -> DIO a
liftDistributedUnsafe = DIO . const

-- | The default parameters for the 'DIO' computation
defaultDIOParams :: DIOParams
defaultDIOParams =
  DIOParams { dioLoggingPriority = DEBUG,
              dioUndoableLogSizeThreshold = 500000,
              dioOutputMessageQueueSizeThreshold = 10000,
              dioSyncTimeout = 5000000,
              dioAllowPrematureIO = False,
              dioAllowProcessingOutdatedMessage = False
            }

-- | Return the parameters of the current computation.
dioParams :: DIO DIOParams
dioParams = DIO $ return . dioParams0

-- | Return the chanel of messages.
messageChannel :: DIO (Channel LocalProcessMessage)
messageChannel = DIO $ return . dioChannel

-- | Return the process identifier of the inbox that receives messages.
messageInboxId :: DIO DP.ProcessId
messageInboxId = DIO $ return . dioInboxId

-- | Return the time server process identifier.
timeServerId :: DIO DP.ProcessId
timeServerId = DIO $ return . dioTimeServerId

-- | Terminate the simulation including the processes in
-- all nodes connected to the time server.
terminateDIO :: DIO ()
terminateDIO =
  do logDIO INFO "Terminating the simulation..."
     sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       DP.send receiver (TerminateTimeServerMessage sender)

-- | Unregister the simulation process from the time server
-- without affecting the processes in other nodes connected to
-- the corresponding time server.
unregisterDIO :: DIO ()
unregisterDIO =
  do logDIO INFO "Unregistering the simulation process..."
     sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       DP.send receiver (UnregisterLocalProcessMessage sender)

-- | Run the computation using the specified parameters along with time server process
-- identifier and return the inbox process identifier and a new simulation process.
runDIO :: DIO a -> DIOParams -> DP.ProcessId -> DP.Process (DP.ProcessId, DP.Process a)
runDIO m ps serverId =
  do ch <- liftIO newChannel
     inboxId <-
       DP.spawnLocal $
       forever $
       do m <- DP.expect :: DP.Process LocalProcessMessage
          liftIO $
            writeChannel ch m
          when (m == TerminateLocalProcessMessage) $
            do ---
               logProcess ps INFO "Terminating the inbox process..."
               ---
               DP.terminate
     ---
     logProcess ps INFO "Registering the simulation process..."
     ---
     DP.send serverId (RegisterLocalProcessMessage inboxId)
     return (inboxId, unDIO m DIOContext { dioChannel = ch,
                                           dioInboxId = inboxId,
                                           dioTimeServerId = serverId,
                                           dioParams0 = ps })

-- | Log the message with the specified priority.
logDIO :: Priority -> String -> DIO ()
{-# INLINE logDIO #-}
logDIO p message =
  do ps <- dioParams
     when (dioLoggingPriority ps <= p) $
       liftDistributedUnsafe $
       DP.say $
       embracePriority p ++ " " ++ message

-- | Log the message with the specified priority.
logProcess :: DIOParams -> Priority -> String -> DP.Process ()
{-# INLINE logProcess #-}
logProcess ps p message =
  when (dioLoggingPriority ps <= p) $
  DP.say $
  embracePriority p ++ " " ++ message
