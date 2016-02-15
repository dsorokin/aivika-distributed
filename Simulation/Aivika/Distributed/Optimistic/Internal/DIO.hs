
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
        DIOParams,
        runDIO,
        terminateSimulation,
        unregisterSimulation,
        messageChannel,
        messageInboxId,
        timeServerId,
        logSizeThreshold,
        liftDistributedUnsafe) where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Exception (throw)
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Trans.Exception

import Simulation.Aivika.Distributed.Optimistic.Internal.Channel
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer

-- | The parameters for the 'DIO' computation.
data DIOParams = DIOParams

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
               dioTimeServerId :: DP.ProcessId
               -- ^ The time server process
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
    DP.catch (m ps) (\e -> unDIO (h e) ps)

  finallyComp (DIO m1) (DIO m2) = DIO $ \ps ->
    DP.finally (m1 ps) (m2 ps)
  
  throwComp e = DIO $ \ps ->
    throw e

-- | Lift the distributed 'Process' computation.
liftDistributedUnsafe :: DP.Process a -> DIO a
liftDistributedUnsafe = DIO . const

-- | Return the chanel of messages.
messageChannel :: DIO (Channel LocalProcessMessage)
messageChannel = DIO $ return . dioChannel

-- | Return the process identifier of the inbox that receives messages.
messageInboxId :: DIO DP.ProcessId
messageInboxId = DIO $ return . dioInboxId

-- | Return the time server process identifier.
timeServerId :: DIO DP.ProcessId
timeServerId = DIO $ return . dioTimeServerId

-- | Return the log size threshold.
logSizeThreshold :: DIO Int
logSizeThreshold = return 100000

-- | Terminate the simulation including the processes in
-- all nodes connected to the time server.
terminateSimulation :: DIO ()
terminateSimulation =
  do sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       do ---
          DP.say "Terminating the simulation..."
          ---
          DP.send receiver (TerminateTimeServerMessage sender)

-- | Unregister the simulation process from the time server
-- without affecting the processes in other nodes connected to
-- the corresponding time server.
unregisterSimulation :: DIO ()
unregisterSimulation =
  do sender   <- messageInboxId
     receiver <- timeServerId
     liftDistributedUnsafe $
       do ---
          DP.say "Unregistering the simulation process..."
          ---
          DP.send receiver (UnregisterLocalProcessMessage sender)

-- | Run the computation using the specified time server process identifier.
runDIO :: DIO a -> DP.ProcessId -> DP.Process a
runDIO m serverId =
  do ch <- liftIO newChannel
     inboxId <-
       DP.spawnLocal $
       forever $
       do m <- DP.expect :: DP.Process LocalProcessMessage
          liftIO $
            writeChannel ch m
          when (m == TerminateLocalProcessMessage) $
            do ---
               DP.say "Terminating the inbox process..."
               ---
               DP.terminate
     ---
     DP.say "Registering the simulation process..."
     ---
     DP.send serverId (RegisterLocalProcessMessage inboxId)
     unDIO m DIOContext { dioChannel = ch,
                          dioInboxId = inboxId,
                          dioTimeServerId = serverId }
