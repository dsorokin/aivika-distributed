
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Ref.Base.Lazy
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- Here is an implementation of lazy mutable references, where
-- 'DIO' is an instance of 'MonadRef' and 'MonadRef0'.
--
module Simulation.Aivika.Distributed.Optimistic.Ref.Base.Lazy () where

import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Ref.Base.Lazy

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import qualified Simulation.Aivika.Distributed.Optimistic.Internal.Ref.Lazy as R

-- | The implementation of lazy mutable references.
instance MonadRef DIO where

  -- | The lazy mutable reference.
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

instance MonadRef0 DIO where

  {-# INLINE newRef0 #-}
  newRef0 = fmap Ref . R.newRef0
