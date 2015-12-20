
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
module Simulation.Aivika.Distributed.Optimistic.Ref.Base where

import Data.IORef

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Trans.Ref.Base

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog

-- | The implementation of mutable references.
instance MonadRef DIO where

  -- | The mutable reference.
  newtype Ref DIO a = Ref { refValue :: IORef a }

  newRef a =
    Simulation $ \r ->
    do x <- liftIOUnsafe $ newIORef a
       return Ref { refValue = x }
     
  readRef r = Event $ \p ->
    liftIOUnsafe $ readIORef (refValue r)

  writeRef r a = Event $ \p ->
    do let log = queueLog $ runEventQueue (pointRun p)
       a0 <- liftIOUnsafe $ readIORef (refValue r)
       invokeEvent p $
         writeLog log $
         liftIOUnsafe $ writeIORef (refValue r) a0
       a `seq` liftIOUnsafe $ writeIORef (refValue r) a

  modifyRef r f = Event $ \p -> 
    do a <- liftIOUnsafe $ readIORef (refValue r)
       let b   = f a
           log = queueLog $ runEventQueue (pointRun p)
       invokeEvent p $
         writeLog log $
         liftIOUnsafe $ writeIORef (refValue r) a
       b `seq` liftIOUnsafe $ writeIORef (refValue r) b

  equalRef (Ref r1) (Ref r2) = (r1 == r2)
