
{-# LANGUAGE FlexibleInstances #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.IO
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines functions for direct embedding 'IO' computations.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.IO
       (MonadIOUnsafe(..)) where

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

-- | Allows embedding unsafe 'IO' computations.
class MonadIOUnsafe m where

  -- | Lift the computation.
  liftIOUnsafe :: IO a -> m a

instance MonadIOUnsafe DIO where
  liftIOUnsafe = DIO . const . liftIO

instance MonadIOUnsafe (Parameter DIO) where
  liftIOUnsafe = liftComp . DIO . const . liftIO 

instance MonadIOUnsafe (Simulation DIO) where
  liftIOUnsafe = liftComp . DIO . const . liftIO 

instance MonadIOUnsafe (Dynamics DIO) where
  liftIOUnsafe = liftComp . DIO . const . liftIO 
  
instance MonadIOUnsafe (Event DIO) where
  liftIOUnsafe = liftComp . DIO . const . liftIO 
