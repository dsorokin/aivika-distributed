
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
        enqueueMessage,
        messageEnqueued) where

import Data.Maybe
import Data.IORef

import Control.Monad
import Control.Monad.Trans

import Simulation.Aivika.Vector
import Simulation.Aivika.Trans.Comp
import Simulation.Aivika.Trans.Simulation
import Simulation.Aivika.Trans.Dynamics
import Simulation.Aivika.Trans.Event
import Simulation.Aivika.Trans.Signal

import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO
import Simulation.Aivika.Distributed.Optimistic.DIO

-- | Specifies the input message queue.
data InputMessageQueue =
  InputMessageQueue { inputMessageRollbackPre :: Double -> DIO (),
                      -- ^ Rollback the operations till the specified time before actual changes.
                      inputMessageRollbackPost :: Double -> DIO (),
                      -- ^ Rollback the operations till the specified time after actual changes.
                      inputMessageSource :: SignalSource DIO Message,
                      -- ^ The message source.
                      inputMessages :: Vector InputMessageQueueItem,
                      -- ^ The input messages.
                      inputMessageIndex :: IORef Int
                      -- ^ An index of the next actual item.
                    }

-- | Specified the input message queue item.
data InputMessageQueueItem =
  InputMessageQueueItem { itemMessage :: Message,
                          -- ^ The item message.
                          itemEvent :: IORef (Maybe (EventCancellation DIO))
                          -- ^ A cancellable event for the item.
                        }

-- | Create a new input message queue.
newInputMessageQueue :: (Double -> DIO ())
                        -- ^ rollback operations till the specified time before actual changes
                        -> (Double -> DIO ())
                        -- ^ rollback operations till the specified time after actual changes
                        -> DIO InputMessageQueue
newInputMessageQueue rollbackPre rollbackPost =
  do ms <- liftIOUnsafe newVector
     r  <- liftIOUnsafe $ newIORef 0
     s  <- newSignalSource0
     return InputMessageQueue { inputMessageRollbackPre = rollbackPre,
                                inputMessageRollbackPost = rollbackPost,
                                inputMessageSource = s,
                                inputMessages = ms,
                                inputMessageIndex = r }

-- | Raised when the message is enqueued.
messageEnqueued :: InputMessageQueue -> Signal DIO Message
messageEnqueued q = publishSignal (inputMessageSource q)

-- | Enqueue a new message ignoring the duplicated messages.
enqueueMessage :: InputMessageQueue -> Message -> Event DIO ()
enqueueMessage q m =
  do i0 <- liftIOUnsafe $ readIORef (inputMessageIndex q)
     t0 <- liftDynamics time
     let t = messageReceiveTime m
     (i, f) <- liftIOUnsafe $ findAntiMessage q m
     case f of
       Nothing -> return ()
       Just f  ->
         if i < i0 || t < t0
         then do i' <- liftIOUnsafe $ leftMessageIndex q m i
                 let t' = messageReceiveTime m
                 liftComp $
                   inputMessageRollbackPre q t'
                 liftIOUnsafe $
                   writeIORef (inputMessageIndex q) i'
                 n <- liftIOUnsafe $ vectorCount (inputMessages q)
                 forM_ [i' .. n-1] $ unregisterMessage q
                 if f
                   then annihilateMessage q i
                   else liftIOUnsafe $ insertMessage q m i
                 n <- liftIOUnsafe $ vectorCount (inputMessages q)
                 forM_ [i' .. n-1] $ registerMessage q
                 liftComp $
                   inputMessageRollbackPost q t'
         else if f
              then annihilateMessage q i
              else do liftIOUnsafe $ insertMessage q m i
                      registerMessage q i

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
  do right <- lookupRightMessageIndex q m
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
annihilateMessage :: InputMessageQueue -> Int -> Event DIO ()
annihilateMessage q i =
  do item <- liftIOUnsafe $ readVector (inputMessages q) i
     liftIOUnsafe $ vectorDeleteAt (inputMessages q) i
     x <- liftIOUnsafe $ readIORef (itemEvent item)
     case x of
       Nothing -> return ()
       Just e  -> cancelEvent e

-- | Register a message at the specified index.
registerMessage :: InputMessageQueue -> Int -> Event DIO ()
registerMessage q i =
  do item <- liftIOUnsafe $ readVector (inputMessages q) i
     let m = itemMessage item
     e <- enqueueEventWithCancellation (messageReceiveTime m) $
          do liftIOUnsafe $ modifyIORef' (inputMessageIndex q) (+ 1)
             unless (messageAntiToggle m) $
               triggerSignal (inputMessageSource q) m
     liftIOUnsafe $ writeIORef (itemEvent item) (Just e)

-- | Unregister a message at the specified index.
unregisterMessage :: InputMessageQueue -> Int -> Event DIO ()
unregisterMessage q i =
  do item <- liftIOUnsafe $ readVector (inputMessages q) i
     x <- liftIOUnsafe $ readIORef (itemEvent item)
     case x of
       Nothing -> return ()
       Just e  -> cancelEvent e

-- | Insert a new message.
insertMessage :: InputMessageQueue -> Message -> Int -> IO ()
insertMessage q m i =
  do r <- newIORef Nothing
     let item = InputMessageQueueItem m r
     vectorInsert (inputMessages q) i item

-- | Search for the rightmost message index.
lookupRightMessageIndex' :: InputMessageQueue -> Message -> Int -> Int -> IO Int
lookupRightMessageIndex' q m left right =
  if left > right
  then return $ - (right + 1) - 1
  else  
    do let index = ((left + 1) + right) `div` 2
       item <- readVector (inputMessages q) index
       let m' = itemMessage item
           t  = messageReceiveTime m
           t' = messageReceiveTime m'
       if t' > t
         then lookupRightMessageIndex' q m left (index - 1)
         else if t' < t
              then lookupRightMessageIndex' q m (index + 1) right
              else if index == right
                   then return right
                   else lookupRightMessageIndex' q m index right
 
-- | Search for the rightmost message index.
lookupRightMessageIndex :: InputMessageQueue -> Message -> IO Int
lookupRightMessageIndex q m =
  do n <- vectorCount (inputMessages q)
     lookupRightMessageIndex' q m 0 (n - 1)
