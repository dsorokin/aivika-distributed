
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
        DIOParams(..),
        runDIO,
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
  DIOParams { dioChannel :: Channel DIOMessage
              -- The channel of messages.
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

-- | The message type.
data DIOMessage = DIOQueueMessage Message
                | DIOGlobalTimeMessage GlobalTimeMessage
                | DIOLocalTimeMessageResp LocalTimeMessageResp
