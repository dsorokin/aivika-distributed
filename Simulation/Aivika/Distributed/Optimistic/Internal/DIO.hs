
{-# LANGUAGE MultiParamTypeClasses #-}

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
        liftIOUnsafe) where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Distributed.Process (Process)

import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.DES
import Simulation.Aivika.Trans.Exception
import Simulation.Aivika.Trans.Generator
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Ref.Base
import Simulation.Aivika.Trans.QueueStrategy

-- | The distributed computation based on 'IO'.
newtype DIO a = DIO { runDIO :: Process a
                      -- ^ Run the computation.
                    }

instance Monad DIO where

  return = DIO . return
  (DIO m) >>= k = DIO $ m >>= runDIO . k

instance Applicative DIO where

  pure = return
  (<*>) = ap

instance Functor DIO where
  
  fmap f (DIO m) = DIO $ fmap f m 

instance MonadDES DIO

instance MonadRef DIO

instance EventQueueing DIO

instance EnqueueStrategy DIO LCFS
instance EnqueueStrategy DIO FCFS

instance DequeueStrategy DIO LCFS
instance DequeueStrategy DIO FCFS

instance QueueStrategy DIO LCFS
instance QueueStrategy DIO FCFS

instance MonadComp DIO

instance MonadException DIO

instance MonadGenerator DIO

-- | Lift 'IO' computation in an unsafe manner.
liftIOUnsafe :: IO a -> DIO a
liftIOUnsafe = DIO . liftIO
