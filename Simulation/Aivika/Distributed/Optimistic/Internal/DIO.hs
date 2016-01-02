
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.DIO
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
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
        dioChannel,
        dioReceiverId,
        dioTimeServerId,
        liftDistributedUnsafe) where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Exception (throw)
import Control.Distributed.Process (Process, ProcessId, catch, finally)

import Simulation.Aivika.Trans.Exception

import Simulation.Aivika.Distributed.Optimistic.Internal.Channel
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer

-- | The distributed computation based on 'IO'.
newtype DIO a = DIO { unDIO :: DIOParams -> Process a
                      -- ^ Unwrap the computation.
                    }

-- | The parameters for the 'DIO' computation.
data DIOParams =
  DIOParams { dioParamChannel :: Channel DIOMessage,
              -- The channel of messages.
              dioParamReceiverId :: ProcessId,
              -- The receiver process
              dioParamTimeServerId :: ProcessId
              -- The time server process
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
    catch (m ps) (\e -> unDIO (h e) ps)

  finallyComp (DIO m1) (DIO m2) = DIO $ \ps ->
    finally (m1 ps) (m2 ps)
  
  throwComp e = DIO $ \ps ->
    throw e

-- | Lift the distributed 'Process' computation.
liftDistributedUnsafe :: Process a -> DIO a
liftDistributedUnsafe = DIO . const

-- | Run the computation.
runDIO :: DIO () -> Process ProcessId
runDIO = undefined

-- | Return the chanel of messages.
dioChannel :: DIO (Channel DIOMessage)
dioChannel = DIO $ return . dioParamChannel

-- | Return the receiver process identifier.
dioReceiverId :: DIO ProcessId
dioReceiverId = DIO $ return . dioParamReceiverId

-- | Return the time server process identifier.
dioTimeServerId :: DIO ProcessId
dioTimeServerId = DIO $ return . dioParamTimeServerId

-- | The message type.
data DIOMessage = DIOQueueMessage Message
                  -- ^ the message has come from the remote process
                | DIOGlobalTimeMessage GlobalTimeMessage
                  -- ^ the time server sent a global time
                | DIOLocalTimeMessageResp LocalTimeMessageResp
                  -- ^ the time server responded to our notification about the local time
                | DIOTerminateMessage
                  -- ^ the time server asked to terminate the process
