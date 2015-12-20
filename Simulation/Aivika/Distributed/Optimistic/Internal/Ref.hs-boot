
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Ref
-- Copyright  : Copyright (c) 2009-2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This is an hs-boot file.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Ref
       (Ref,
        newRef,
        readRef,
        writeRef,
        modifyRef) where

import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

data Ref a

instance Eq (Ref a)

newRef :: a -> Simulation DIO (Ref a)
     
readRef :: Ref a -> Event DIO a

writeRef :: Ref a -> a -> Event DIO ()

modifyRef :: Ref a -> (a -> a) -> Event DIO ()
