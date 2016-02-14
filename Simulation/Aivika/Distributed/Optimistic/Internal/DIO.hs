
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

-- | The distributed computation based on 'IO'.
newtype DIO a = DIO { unDIO :: DIOParams -> DP.Process a
                      -- ^ Unwrap the computation.
                    }

-- | The parameters for the 'DIO' computation.
data DIOParams =
  DIOParams { dioParamChannel :: Channel LocalProcessMessage,
              -- ^ The channel of messages.
              dioParamInboxId :: DP.ProcessId,
              -- ^ The inbox process identifier.
              dioParamTimeServerId :: DP.ProcessId
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

-- | Run the computation.
runDIO :: DIO () -> DP.Process DP.ProcessId
runDIO = undefined

-- | Return the chanel of messages.
messageChannel :: DIO (Channel LocalProcessMessage)
messageChannel = DIO $ return . dioParamChannel

-- | Return the process identifier of the inbox that receives messages.
messageInboxId :: DIO DP.ProcessId
messageInboxId = DIO $ return . dioParamInboxId

-- | Return the time server process identifier.
timeServerId :: DIO DP.ProcessId
timeServerId = DIO $ return . dioParamTimeServerId

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
