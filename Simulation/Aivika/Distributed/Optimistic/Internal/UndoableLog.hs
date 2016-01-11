
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an output message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
       (UndoableLog,
        newUndoableLog,
        writeLog,
        rollbackLog,
        reduceLog) where

import Control.Monad
import Control.Monad.Trans

import qualified Simulation.Aivika.DoubleLinkedList as DLL
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Dynamics
import Simulation.Aivika.Trans.Event

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO

-- | Specified an undoable log with ability to rollback the operations.
data UndoableLog =
  UndoableLog { logItems :: DLL.DoubleLinkedList UndoableItem
                -- ^ The items that can be undone.
              }

data UndoableItem =
  UndoableItem { itemTime :: Double,
                 -- ^ The time at which the operation had occured.
                 itemUndo :: DIO ()
                 -- ^ Undo the operation
               }

-- | Create an undoable log.
newUndoableLog :: DIO UndoableLog
newUndoableLog =
  do xs <- liftIOUnsafe DLL.newList
     return UndoableLog { logItems = xs }

-- | Write a new undoable operation.
writeLog :: UndoableLog -> DIO () -> Event DIO ()
writeLog log h =
  do t <- liftDynamics time
     let x = UndoableItem { itemTime = t, itemUndo = h }
     liftIOUnsafe $ DLL.listAddLast (logItems log) x

-- | Rollback the log till the specified time including that one.
rollbackLog :: UndoableLog -> Double -> Event DIO ()
rollbackLog log t =
  do f <- liftIOUnsafe $ DLL.listNull (logItems log)
     unless f $
       do x <- liftIOUnsafe $ DLL.listLast (logItems log)
          when (t <= itemTime x) $
            do liftIOUnsafe $ DLL.listRemoveLast (logItems log)
               liftComp (itemUndo x)
               rollbackLog log t

-- | Reduce the log removing all items older than the specified time.
reduceLog :: UndoableLog -> Double -> Event DIO ()
reduceLog log t =
  do f <- liftIOUnsafe $ DLL.listNull (logItems log)
     unless f $
       do x <- liftIOUnsafe $ DLL.listFirst (logItems log)
          when (itemTime x < t) $
            do liftIOUnsafe $ DLL.listRemoveFirst (logItems log)
               reduceLog log t

