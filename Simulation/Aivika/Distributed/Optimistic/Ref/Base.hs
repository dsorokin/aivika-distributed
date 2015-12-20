
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Ref.Base
-- Copyright  : Copyright (c) 2009-2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- The implementation of mutable references.
--
module Simulation.Aivika.Distributed.Optimistic.Ref.Base () where

import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Trans.Ref.Base

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import qualified Simulation.Aivika.Distributed.Optimistic.Internal.Ref as R

-- | The implementation of mutable references.
instance MonadRef DIO where

  -- | The mutable reference.
  newtype Ref DIO a = Ref { refValue :: R.Ref a }

  {-# INLINE newRef #-}
  newRef = fmap Ref . R.newRef 

  {-# INLINE readRef #-}
  readRef (Ref r) = R.readRef r

  {-# INLINE writeRef #-}
  writeRef (Ref r) = R.writeRef r

  {-# INLINE modifyRef #-}
  modifyRef (Ref r) = R.modifyRef r

  {-# INLINE equalRef #-}
  equalRef (Ref r1) (Ref r2) = (r1 == r2)
