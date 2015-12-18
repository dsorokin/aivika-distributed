
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
import Control.Distributed.Process (Process)

-- | The distributed computation based on 'IO'.
newtype DIO a = DIO { runDIO :: DIOParams -> Process a
                      -- ^ Run the computation.
                    }

-- | The parameters for the 'DIO' computation.
data DIOParams =
  DIOParams { dioParamDeliveryTimeout :: Int
              -- The timeout in milliseconds for the delivery operation.
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

-- | The default 'DIO' parameters.
defaultDIOParams :: DIOParams
defaultDIOParams =
  DIOParams { dioParamDeliveryTimeout = 60000 }
