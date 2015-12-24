
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Ref
-- Copyright  : Copyright (c) 2009-2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- The implementation of mutable references.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Ref
       (Ref,
        newRef,
        newRef0,
        readRef,
        writeRef,
        modifyRef) where

import Data.IORef

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.Event
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog

-- | A mutable reference.
newtype Ref a = Ref { refValue :: IORef a }

instance Eq (Ref a) where
  (Ref r1) == (Ref r2) = r1 == r2

-- | Create a new reference.
newRef :: a -> Simulation DIO (Ref a)
newRef a =
  do x <- liftIOUnsafe $ newIORef a
     return Ref { refValue = x }

-- | Create a new reference.
newRef0 :: a -> DIO (Ref a)
newRef0 a =
  do x <- liftIOUnsafe $ newIORef a
     return Ref { refValue = x }
     
-- | Read the value of a reference.
readRef :: Ref a -> Event DIO a
readRef r = Event $ \p ->
  liftIOUnsafe $ readIORef (refValue r)

-- | Write a new value into the reference.
writeRef :: Ref a -> a -> Event DIO ()
writeRef r a = Event $ \p ->
  do let log = queueLog $ runEventQueue (pointRun p)
     a0 <- liftIOUnsafe $ readIORef (refValue r)
     invokeEvent p $
       writeLog log $
       liftIOUnsafe $ writeIORef (refValue r) a0
     a `seq` liftIOUnsafe $ writeIORef (refValue r) a

-- | Mutate the contents of the reference.
modifyRef :: Ref a -> (a -> a) -> Event DIO ()
modifyRef r f = Event $ \p ->
  do a <- liftIOUnsafe $ readIORef (refValue r)
     let b   = f a
         log = queueLog $ runEventQueue (pointRun p)
     invokeEvent p $
       writeLog log $
       liftIOUnsafe $ writeIORef (refValue r) a
     b `seq` liftIOUnsafe $ writeIORef (refValue r) b
