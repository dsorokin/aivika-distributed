
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
        defaultDIOParams) where

import Control.Applicative
import Control.Monad
import Control.Exception (throw)
import Control.Distributed.Process (Process, catch, finally)

import Simulation.Aivika.Trans.Exception

-- | The distributed computation based on 'IO'.
newtype DIO a = DIO { runDIO :: DIOParams -> Process a
                      -- ^ Run the computation.
                    }

-- | The parameters for the 'DIO' computation.
data DIOParams =
  DIOParams { dioParamRecallTimeout :: Int
              -- The timeout in milliseconds for delivering an anti-message.
            }

instance Monad DIO where

  {-# INLINE return #-}
  return = DIO . const . return

  {-# INLINE (>>=) #-}
  (DIO m) >>= k = DIO $ \ps ->
    m ps >>= \a ->
    let m' = runDIO (k a) in m' ps

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
    catch (m ps) (\e -> runDIO (h e) ps)

  finallyComp (DIO m1) (DIO m2) = DIO $ \ps ->
    finally (m1 ps) (m2 ps)
  
  throwComp e = DIO $ \ps ->
    throw e

-- | The default 'DIO' parameters.
defaultDIOParams :: DIOParams
defaultDIOParams =
  DIOParams { dioParamRecallTimeout = 60000 }
