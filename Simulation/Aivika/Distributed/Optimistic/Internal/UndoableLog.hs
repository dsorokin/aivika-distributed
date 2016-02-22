
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
        reduceLog,
        logSize,
        logRollbackVersion) where

import Data.IORef

import Control.Monad
import Control.Monad.Trans

import qualified Simulation.Aivika.DoubleLinkedList as DLL
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO

-- | Specified an undoable log with ability to rollback the operations.
data UndoableLog =
  UndoableLog { logItems :: DLL.DoubleLinkedList UndoableItem,
                -- ^ The items that can be undone.
                logRollbackVersionRef :: IORef Int
                -- ^ The version of the rollback.
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
     v  <- liftIOUnsafe $ newIORef 0
     return UndoableLog { logItems = xs,
                          logRollbackVersionRef = v }

-- | Write a new undoable operation.
writeLog :: UndoableLog -> DIO () -> Event DIO ()
{-# INLINE writeLog #-}
writeLog log h =
  Event $ \p ->
  do let x = UndoableItem { itemTime = pointTime p, itemUndo = h }
     ---
     logDIO DEBUG $ "Writing the log at t = " ++ show (itemTime x)
     ---
     liftIOUnsafe $
       do f <- DLL.listNull (logItems log)
          if f
            then DLL.listAddLast (logItems log) x
            else do x0 <- DLL.listLast (logItems log)
                    when (itemTime x < itemTime x0) $
                      error $
                      "The logging data are not sorted by time (" ++
                      (show $ itemTime x) ++ " < " ++
                      (show $ itemTime x0) ++ "): writeLog"
                    DLL.listAddLast (logItems log) x

-- | Rollback the log till the specified time either including that one or not.
rollbackLog :: UndoableLog -> Double -> Bool -> DIO ()
rollbackLog log t including =
  do liftIOUnsafe $ modifyIORef' (logRollbackVersionRef log) (+ 1)
     ---
     logDIO DEBUG $ "Rolling the log back to t = " ++ show t
     ---
     loop
       where
         loop =
           do f <- liftIOUnsafe $ DLL.listNull (logItems log)
              unless f $
                do x <- liftIOUnsafe $ DLL.listLast (logItems log)
                   when ((t < itemTime x) || (including && t == itemTime x)) $
                     do liftIOUnsafe $ DLL.listRemoveLast (logItems log)
                        itemUndo x
                        loop

-- | Reduce the log removing all items older than the specified time.
reduceLog :: UndoableLog -> Double -> IO ()
reduceLog log t =
  do f <- DLL.listNull (logItems log)
     unless f $
       do x <- DLL.listFirst (logItems log)
          when (itemTime x < t) $
            do DLL.listRemoveFirst (logItems log)
               reduceLog log t

-- | Return the log size.
logSize :: UndoableLog -> IO Int
logSize log = DLL.listCount (logItems log)

-- | Return the rolback version.
logRollbackVersion :: UndoableLog -> IO Int
logRollbackVersion = readIORef . logRollbackVersionRef
