
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines an input message queue.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.InputMessageQueue
       (InputMessageQueue,
        newInputMessageQueue,
        inputMessageQueueIndex,
        inputMessageQueueSize,
        enqueueMessage,
        messageEnqueued,
        retryInputMessages,
        reduceInputMessages) where

import Data.Maybe
import Data.List
import Data.IORef

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Vector
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Dynamics
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.UndoableLog
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeWarp
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Specifies the input message queue.
data InputMessageQueue =
  InputMessageQueue { inputMessageLog :: UndoableLog,
                      -- ^ the Redo/Undo log.
                      inputMessageRollbackPre :: Double -> Bool -> Event DIO (),
                      -- ^ Rollback the operations till the specified time before actual changes either including the time or not.
                      inputMessageRollbackPost :: Double -> Bool -> Event DIO (),
                      -- ^ Rollback the operations till the specified time after actual changes either including the time or not.
                      inputMessageRollbackTime :: Double -> Event DIO (),
                      -- ^ Rollback the event time.
                      inputMessageSource :: SignalSource DIO Message,
                      -- ^ The message source.
                      inputMessages :: Vector InputMessageQueueItem,
                      -- ^ The input messages.
                      inputMessageIndex :: IORef Int,
                      -- ^ An index of the next actual item.
                      inputMessageActions :: IORef [Event DIO ()]
                      -- ^ The list of actions to perform.
                    }

-- | Specified the input message queue item.
data InputMessageQueueItem =
  InputMessageQueueItem { itemMessage :: Message,
                          -- ^ The item message.
                          itemAnnihilated :: IORef Bool
                          -- ^ Whether the item was annihilated.
                        }

-- | Create a new input message queue.
newInputMessageQueue :: UndoableLog
                        -- ^ the Redo/Undo log
                        -> (Double -> Bool -> Event DIO ())
                        -- ^ rollback operations till the specified time before actual changes either including the time or not
                        -> (Double -> Bool -> Event DIO ())
                        -- ^ rollback operations till the specified time after actual changes either including the time or not
                        -> (Double -> Event DIO ())
                        -- ^ rollback the event time
                        -> DIO InputMessageQueue
newInputMessageQueue log rollbackPre rollbackPost rollbackTime =
  do ms <- liftIOUnsafe newVector
     r1 <- liftIOUnsafe $ newIORef 0
     r2 <- liftIOUnsafe $ newIORef []
     s  <- newSignalSource0
     return InputMessageQueue { inputMessageLog = log,
                                inputMessageRollbackPre = rollbackPre,
                                inputMessageRollbackPost = rollbackPost,
                                inputMessageRollbackTime = rollbackTime,
                                inputMessageSource = s,
                                inputMessages = ms,
                                inputMessageIndex = r1,
                                inputMessageActions = r2 }

-- | Return the input message queue index.
inputMessageQueueIndex :: InputMessageQueue -> IO Int
inputMessageQueueIndex = readIORef . inputMessageIndex

-- | Return the input message queue size.
inputMessageQueueSize :: InputMessageQueue -> IO Int
inputMessageQueueSize = vectorCount . inputMessages

-- | Raised when the message is enqueued.
messageEnqueued :: InputMessageQueue -> Signal DIO Message
messageEnqueued q = publishSignal (inputMessageSource q)

-- | Enqueue a new message ignoring the duplicated messages.
enqueueMessage :: InputMessageQueue -> Message -> TimeWarp DIO ()
enqueueMessage q m =
  TimeWarp $ \p ->
  do i0 <- liftIOUnsafe $ readIORef (inputMessageIndex q)
     let t  = messageReceiveTime m
         t0 = pointTime p
     (i, f) <- liftIOUnsafe $ findAntiMessage q m
     case f of
       Nothing -> return ()
       Just True | (i < i0 || t < t0) ->
         do -- found an anti-message at the specified index
            i' <- liftIOUnsafe $ leftMessageIndex q m i
            let p' = pastPoint t p
            logRollbackInputMessages t0 t True
            invokeEvent p' $
              rollbackInputMessages q t True $
              Event $ \p' ->
              liftIOUnsafe $
              do writeIORef (inputMessageIndex q) i'
                 annihilateMessage q i
            invokeEvent p' $
              inputMessageRollbackTime q t
       Just False | (i < i0 || t < t0) ->
         do -- insert the message at the specified right index
            let p' = pastPoint t p
            logRollbackInputMessages t0 t False
            invokeEvent p' $
              rollbackInputMessages q t False $
              Event $ \p' ->
              do liftIOUnsafe $
                   do writeIORef (inputMessageIndex q) i
                      insertMessage q m i
                 invokeEvent p' $ activateMessage q i
            invokeEvent p' $
              inputMessageRollbackTime q t
       Just True  ->
         liftIOUnsafe $ annihilateMessage q i
       Just False ->
         do liftIOUnsafe $ insertMessage q m i
            invokeEvent p $ activateMessage q i

-- | Log the rollback.
logRollbackInputMessages :: Double -> Double -> Bool -> DIO ()
logRollbackInputMessages t0 t including =
  logDIO NOTICE $
  "Rollback at t = " ++ (show t0) ++ " --> " ++ (show t) ++
  (if not including then " not including" else "")

-- | Enqueue a new message ignoring the duplicated messages.
retryInputMessages :: InputMessageQueue -> Double -> TimeWarp DIO ()
retryInputMessages q t =
  TimeWarp $ \p ->
  do i <- liftIOUnsafe $ lookupLeftMessageIndex q t
     let i' = if i >= 0 then i else (- i - 1)
     invokeEvent p $
       rollbackInputMessages q t True $
       liftIOUnsafe $
       writeIORef (inputMessageIndex q) i'

-- | Rollback the input messages till the specified time, either including the time or not, and apply the given computation.
rollbackInputMessages :: InputMessageQueue -> Double -> Bool -> Event DIO () -> Event DIO ()
rollbackInputMessages q t including m =
  Event $ \p ->
  do liftIOUnsafe $
       requireEmptyMessageActions q
     invokeEvent p $
       inputMessageRollbackPre q t including
     invokeEvent p m
     invokeEvent p $
       performMessageActions q
     invokeEvent p $
       inputMessageRollbackPost q t including

-- | Return the point in the past.
pastPoint :: Double -> Point DIO -> Point DIO
pastPoint t p = p'
  where sc = pointSpecs p
        t0 = spcStartTime sc
        dt = spcDT sc
        n  = fromIntegral $ floor ((t - t0) / dt)
        p' = p { pointTime = t,
                 pointIteration = n,
                 pointPhase = -1 }

-- | Require that the there are no message actions.
requireEmptyMessageActions :: InputMessageQueue -> IO ()
requireEmptyMessageActions q =
  do xs <- readIORef (inputMessageActions q)
     unless (null xs) $
       error "There are incomplete message actions: requireEmptyMessageActions"

-- | Perform the message actions
performMessageActions :: InputMessageQueue -> Event DIO ()
performMessageActions q =
  do xs <- liftIOUnsafe $ readIORef (inputMessageActions q)
     liftIOUnsafe $ writeIORef (inputMessageActions q) []
     sequence_ xs

-- | Return the leftmost index for the current message.
leftMessageIndex :: InputMessageQueue -> Message -> Int -> IO Int
leftMessageIndex q m i
  | i == 0    = return 0
  | otherwise = do let i' = i - 1
                   item' <- readVector (inputMessages q) i'
                   let m' = itemMessage item'
                       t  = messageReceiveTime m
                       t' = messageReceiveTime m'
                   if t' > t
                     then error "Incorrect index: leftMessageIndex"
                     else if t' < t
                          then return i
                          else leftMessageIndex q m i'

-- | Find an anti-message and return the index with 'True'; otherwise,
-- return the insertion index within the current receive time with 'False'.
--
-- The second result is 'Nothing' if the message is duplicated.
findAntiMessage :: InputMessageQueue -> Message -> IO (Int, Maybe Bool)
findAntiMessage q m =
  do right <- lookupRightMessageIndex q (messageReceiveTime m)
     if right < 0
       then return (- right - 1, Just False)
       else let loop i
                  | i < 0     = return (right + 1, Just False)
                  | otherwise =
                    do item <- readVector (inputMessages q) i
                       let m' = itemMessage item
                           t  = messageReceiveTime m
                           t' = messageReceiveTime m'
                       if t' > t
                         then error "Incorrect index: findAntiMessage"
                         else if t' < t
                              then return (right + 1, Just False)
                              else if antiMessages m m'
                                   then return (i, Just True)
                                   else if m == m'
                                        then return (i, Nothing)
                                        else loop (i - 1)
            in loop right       

-- | Annihilate a message at the specified index.
annihilateMessage :: InputMessageQueue -> Int -> IO ()
annihilateMessage q i =
  do item <- readVector (inputMessages q) i
     vectorDeleteAt (inputMessages q) i
     writeIORef (itemAnnihilated item) True

-- | Activate a message at the specified index.
activateMessage :: InputMessageQueue -> Int -> Event DIO ()
activateMessage q i =
  do item <- liftIOUnsafe $ readVector (inputMessages q) i
     let m    = itemMessage item
         loop =
           do f <- liftIOUnsafe $ readIORef (itemAnnihilated item)
              unless f $
                do writeLog (inputMessageLog q) $
                     liftIOUnsafe $
                     modifyIORef (inputMessageActions q) (loop :)
                   enqueueEvent (messageReceiveTime m) $
                     do liftIOUnsafe $ modifyIORef' (inputMessageIndex q) (+ 1)
                        f <- liftIOUnsafe $ readIORef (itemAnnihilated item)
                        unless f $
                          triggerSignal (inputMessageSource q) m
     loop

-- | Insert a new message.
insertMessage :: InputMessageQueue -> Message -> Int -> IO ()
insertMessage q m i =
  do r <- newIORef False
     let item = InputMessageQueueItem m r
     vectorInsert (inputMessages q) i item

-- | Search for the rightmost message index.
lookupRightMessageIndex' :: InputMessageQueue -> Double -> Int -> Int -> IO Int
lookupRightMessageIndex' q t left right =
  if left > right
  then return $ - (right + 1) - 1
  else  
    do let index = ((left + 1) + right) `div` 2
       item <- readVector (inputMessages q) index
       let m' = itemMessage item
           t' = messageReceiveTime m'
       if t' > t
         then lookupRightMessageIndex' q t left (index - 1)
         else if t' < t
              then lookupRightMessageIndex' q t (index + 1) right
              else if index == right
                   then return right
                   else lookupRightMessageIndex' q t index right

-- | Search for the leftmost message index.
lookupLeftMessageIndex' :: InputMessageQueue -> Double -> Int -> Int -> IO Int
lookupLeftMessageIndex' q t left right =
  if left > right
  then return $ - (right + 1) - 1
  else  
    do let index = (left + right) `div` 2
       item <- readVector (inputMessages q) index
       let m' = itemMessage item
           t' = messageReceiveTime m'
       if t' > t
         then lookupLeftMessageIndex' q t left (index - 1)
         else if t' < t
              then lookupLeftMessageIndex' q t (index + 1) right
              else if index == left
                   then return left
                   else lookupLeftMessageIndex' q t left index
 
-- | Search for the rightmost message index.
lookupRightMessageIndex :: InputMessageQueue -> Double -> IO Int
lookupRightMessageIndex q t =
  do n <- vectorCount (inputMessages q)
     lookupRightMessageIndex' q t 0 (n - 1)
 
-- | Search for the leftmost message index.
lookupLeftMessageIndex :: InputMessageQueue -> Double -> IO Int
lookupLeftMessageIndex q t =
  do n <- vectorCount (inputMessages q)
     lookupLeftMessageIndex' q t 0 (n - 1)

-- | Reduce the input messages till the specified time.
reduceInputMessages :: InputMessageQueue -> Double -> IO ()
reduceInputMessages q t =
  do count <- vectorCount (inputMessages q)
     len   <- loop count 0
     when (len > 0) $
       do vectorDeleteRange (inputMessages q) 0 len
          modifyIORef' (inputMessageIndex q) (\i -> i - len)
            where
              loop n i
                | i >= n    = return i
                | otherwise = do item <- readVector (inputMessages q) i
                                 let m = itemMessage item
                                 if messageReceiveTime m < t
                                   then loop n (i + 1)
                                   else return i

