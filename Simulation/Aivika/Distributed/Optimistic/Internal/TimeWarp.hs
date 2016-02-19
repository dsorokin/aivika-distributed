
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines a computation in the course of which the time may warp.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp
       (TimeWarp(..),
        invokeTimeWarp) where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types

-- | The time warp computation.
newtype TimeWarp m a = TimeWarp (Point m -> m a)

instance Monad m => Monad (TimeWarp m) where

  {-# INLINE return #-}
  return = TimeWarp . const . return

  {-# INLINE (>>=) #-}
  (TimeWarp m) >>= k = TimeWarp $ \p ->
    m p >>= \a ->
    let TimeWarp m' = k a in m' p

instance Applicative m => Applicative (TimeWarp m) where

  {-# INLINE pure #-}
  pure = TimeWarp . const . pure

  {-# INLINE (<*>) #-}
  (TimeWarp x) <*> (TimeWarp y) = TimeWarp $ \p -> x p <*> y p

instance Functor m => Functor (TimeWarp m) where

  {-# INLINE fmap #-}
  fmap f (TimeWarp m) = TimeWarp $ fmap f . m 

-- | Invoke the 'TimeWarp' computation.
invokeTimeWarp :: Point m -> TimeWarp m a -> m a
{-# INLINE invokeTimeWarp #-}
invokeTimeWarp p (TimeWarp m) = m p
