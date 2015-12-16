
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
       (DIO(..)) where

import Control.Applicative
import Control.Monad
import Control.Distributed.Process (Process)

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
