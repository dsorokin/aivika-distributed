
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an undoable log.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
       (UndoableLog,
        newUndoableLog,
        writeLog,
        rollbackLog,
        reduceLog,
        logSize) where

import Data.IORef
import Data.Array.IO.Safe

import Control.Monad
import Control.Monad.Trans

import qualified Simulation.Aivika.DoubleLinkedList as DLL
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO

-- | Specifies an undoable log with ability to rollback the operations.
data UndoableLog =
  UndoableLog { logItemChunks :: DLL.DoubleLinkedList UndoableItemChunk
                -- ^ The chunk of items that can be undone.
              }

-- | A chunk of undoable operation items.
data UndoableItemChunk =
  UndoableItemChunk { chunkItemStart :: IORef Int,
                      -- ^ the start item index in the chunk.
                      chunkItemEnd :: IORef Int,
                      -- ^ the end item index in the chunk.
                      chunkItemTimes :: IOUArray Int Double,
                      -- ^ the times at which the operations had occurred.
                      chunkItemUndo :: IOArray Int (DIO ())
                      -- ^ the undo operations.
                    }

-- | The chunk item capacity.
chunkItemCapacity = 512

-- | Create an undoable log.
newUndoableLog :: DIO UndoableLog
newUndoableLog =
  do xs <- liftIOUnsafe DLL.newList
     return UndoableLog { logItemChunks = xs }

-- | Write a new undoable operation.
writeLog :: UndoableLog -> DIO () -> Event DIO ()
{-# INLINABLE writeLog #-}
writeLog log h =
  Event $ \p ->
  do let t = pointTime p
     ---
     --- logDIO DEBUG $ "Writing the log at t = " ++ show t
     ---
     liftIOUnsafe $
       do f <- DLL.listNull (logItemChunks log)
          if f
            then do ch <- newItemChunk t h
                    DLL.listAddLast (logItemChunks log) ch
            else do ch <- DLL.listLast (logItemChunks log)
                    e  <- readIORef (chunkItemEnd ch)
                    t0 <- readArray (chunkItemTimes ch) (e - 1)
                    when (t < t0) $
                      error $
                      "The logging data are not sorted by time (" ++
                      show t ++ " < " ++
                      show t0 ++ "): writeLog"
                    if e == chunkItemCapacity
                      then do ch <- newItemChunk t h
                              DLL.listAddLast (logItemChunks log) ch
                      else do let e' = e + 1
                              writeArray (chunkItemTimes ch) e t
                              writeArray (chunkItemUndo ch) e h
                              e' `seq` writeIORef (chunkItemEnd ch) e'

-- | Rollback the log till the specified time either including that one or not.
rollbackLog :: UndoableLog -> Double -> Bool -> DIO ()
rollbackLog log t including =
  do ---
     --- logDIO DEBUG $ "Rolling the log back to t = " ++ show t
     ---
     loop
       where
         loop =
           do f <- liftIOUnsafe $ DLL.listNull (logItemChunks log)
              unless f $
                do ch <- liftIOUnsafe $ DLL.listLast (logItemChunks log)
                   s  <- liftIOUnsafe $ readIORef (chunkItemStart ch)
                   let inner e =
                         if e == s
                         then do liftIOUnsafe $ DLL.listRemoveLast (logItemChunks log)
                                 loop
                         else do let e' = e - 1
                                 t0 <- e' `seq` liftIOUnsafe $ readArray (chunkItemTimes ch) e'
                                 when ((t < t0) || (including && t == t0)) $
                                   do h <- liftIOUnsafe $ readArray (chunkItemUndo ch) e'
                                      liftIOUnsafe $ writeArray (chunkItemUndo ch) e' undefined
                                      liftIOUnsafe $ writeIORef (chunkItemEnd ch) e'
                                      h
                                      inner e'
                   e <- liftIOUnsafe $ readIORef (chunkItemEnd ch)
                   inner e

-- | Reduce the log removing all items older than the specified time.
reduceLog :: UndoableLog -> Double -> IO ()
reduceLog log t =
  do f <- DLL.listNull (logItemChunks log)
     unless f $
       do ch <- DLL.listFirst (logItemChunks log)
          e  <- readIORef (chunkItemEnd ch)
          t0 <- readArray (chunkItemTimes ch) (e - 1)
          if t0 < t
            then do DLL.listRemoveFirst (logItemChunks log)
                    reduceLog log t
            else do let loop s =
                          if s == e
                          then error "The log is corrupted: reduceLog"
                          else do t0 <- readArray (chunkItemTimes ch) s
                                  when (t0 < t) $
                                    do let s' = s + 1
                                       writeArray (chunkItemUndo ch) s undefined
                                       s' `seq` writeIORef (chunkItemStart ch) s'
                                       loop s'
                    s <- readIORef (chunkItemStart ch)
                    loop s

-- | Return the log size.
logSize :: UndoableLog -> IO Int
logSize log =
  do n <- DLL.listCount (logItemChunks log)
     if n == 0
       then return 0
       else do n1 <- firstItemChunkSize log
               n2 <- lastItemChunkSize log
               if n == 1
                 then if n1 == n2
                      then return n1
                      else error "The log is corrupted: logSize"
                 else return (n1 + (n - 2) * chunkItemCapacity + n2)

-- | Create a new item chunk.
newItemChunk :: Double -> DIO () -> IO UndoableItemChunk
{-# INLINABLE newItemChunk #-}
newItemChunk t h =
  do times <- newArray_ (0, chunkItemCapacity - 1)
     undo  <- newArray_ (0, chunkItemCapacity - 1)
     start <- newIORef 0
     end   <- newIORef 1
     writeArray times 0 t
     writeArray undo 0 h
     return UndoableItemChunk { chunkItemStart = start,
                                chunkItemEnd = end,
                                chunkItemTimes = times,
                                chunkItemUndo = undo }

-- | Get the item chunk size.
itemChunkSize :: UndoableItemChunk -> IO Int
itemChunkSize ch =
  do s <- readIORef (chunkItemStart ch)
     e <- readIORef (chunkItemEnd ch)
     return (e - s)

-- | Get the first item chunk size; otherwise, return zero.
firstItemChunkSize :: UndoableLog -> IO Int
firstItemChunkSize log =
  do f <- DLL.listNull (logItemChunks log)
     if f
       then return 0
       else do ch <- DLL.listFirst (logItemChunks log)
               itemChunkSize ch

-- | Get the last item chunk size; otherwise, return zero.
lastItemChunkSize :: UndoableLog -> IO Int
lastItemChunkSize log =
  do f <- DLL.listNull (logItemChunks log)
     if f
       then return 0
       else do ch <- DLL.listLast (logItemChunks log)
               itemChunkSize ch
