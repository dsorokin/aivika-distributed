
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
-- Copyright  : Copyright (c) 2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an output message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
       (UndoableLog,
        createUndoableLog,
        writeLog,
        rollbackLog) where

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Vector
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Dynamics
import Simulation.Aivika.Trans.Event

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO

-- | Specified an undoable log with ability to rollback the operations.
data UndoableLog =
  UndoableLog { logItems :: Vector UndoableItem
                -- ^ The items that can be undone.
              }

data UndoableItem =
  UndoableItem { itemTime :: Double,
                 -- ^ The time at which the operation had occured.
                 itemUndo :: DIO ()
                 -- ^ Undo the operation
               }

-- | Lift the 'IO' computation in an unsafe manner.
liftIOUnsafe0 :: IO a -> Simulation DIO a
liftIOUnsafe0 = liftComp . DIO . const . liftIO

-- | Lift the 'IO' computation in an unsafe manner.
liftIOUnsafe :: IO a -> Event DIO a
liftIOUnsafe = liftComp . DIO . const . liftIO

-- | Create an undoable log.
createUndoableLog :: Simulation DIO UndoableLog
createUndoableLog =
  do xs <- liftIOUnsafe0 newVector
     return UndoableLog { logItems = xs }

-- | Write a new undoable operation.
writeLog :: UndoableLog -> DIO () -> Event DIO ()
writeLog log h =
  do t <- liftDynamics time
     let x = UndoableItem { itemTime = t, itemUndo = h }
     liftIOUnsafe $ appendVector (logItems log) x

-- | Rollback the log till the specified time including that one.
rollbackLog :: UndoableLog -> Double -> Event DIO ()
rollbackLog log t =
  do n <- liftIOUnsafe $ vectorCount (logItems log)
     when (n > 0) $
       do x <- liftIOUnsafe $ readVector (logItems log) (n - 1)
          when (t <= itemTime x) $
            do liftIOUnsafe $ vectorDeleteAt (logItems log) (n - 1)
               liftComp (itemUndo x)
               rollbackLog log t


