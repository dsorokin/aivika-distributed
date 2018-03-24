
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.KeepAliveManager
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module is responsible for delivering keep-alive messages.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.KeepAliveManager
       (KeepAliveManager,
        KeepAliveParams(..),
        newKeepAliveManager,
        addKeepAliveReceiver,
        remonitorKeepAliveReceiver,
        existsKeepAliveReceiver,
        trySendKeepAlive,
        trySendKeepAliveUTC) where

import qualified Data.Map as M
import Data.Maybe
import Data.IORef
import Data.Time.Clock

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.Message

-- | The keep-alive parameters.
data KeepAliveParams =
  KeepAliveParams { keepAliveLoggingPriority :: Priority,
                    -- ^ the logging priority
                    keepAliveInterval :: Int
                    -- ^ the interval in microseconds to send keep-alive messages
                  }

-- | The keep-alive manager.
data KeepAliveManager =
  KeepAliveManager { keepAliveParams :: KeepAliveParams,
                     -- ^ the manager parameter
                     keepAliveTimestamp :: IORef UTCTime,
                     -- ^ the keep alive timestamp
                     keepAliveReceivers :: IORef (M.Map DP.ProcessId KeepAliveReceiver)
                     -- ^ the receivers of the keep-alive messages
                   }

data KeepAliveReceiver =
  KeepAliveReceiver { keepAliveReceiverProcess :: DP.ProcessId,
                      -- ^ the receiver of keep-alive messages
                      keepAliveReceiverMonitor :: IORef DP.MonitorRef
                      -- ^ a monitor of the keep-alive receiver
                    }

-- | Create a new keep-alive manager.
newKeepAliveManager :: KeepAliveParams -> IO KeepAliveManager
newKeepAliveManager ps =
  do timestamp <- getCurrentTime >>= newIORef
     receivers <- newIORef M.empty
     return KeepAliveManager { keepAliveParams = ps,
                               keepAliveTimestamp = timestamp,
                               keepAliveReceivers = receivers }

-- | Add the keep-alive message receiver.
addKeepAliveReceiver :: KeepAliveManager -> DP.ProcessId -> DP.Process ()
addKeepAliveReceiver manager pid =
  do ---
     logKeepAliveManager manager INFO $ "Monitoring process " ++ show pid
     ---
     r  <- DP.monitor pid
     r2 <- liftIO $ newIORef r
     let x = KeepAliveReceiver pid r2
     liftIO $
       modifyIORef (keepAliveReceivers manager) $
       M.insert pid x

-- | Remonitor the keep-alive message receiver.
remonitorKeepAliveReceiver :: KeepAliveManager -> DP.ProcessId -> DP.Process ()
remonitorKeepAliveReceiver manager pid =
  do rs <- liftIO $ readIORef (keepAliveReceivers manager)
     case M.lookup pid rs of
       Nothing ->
         do ---
            logKeepAliveManager manager WARNING $ "Could not find the monitored process " ++ show pid
            ---
       Just x ->
         do ---
            logKeepAliveManager manager NOTICE $ "Re-monitoring process " ++ show pid
            ---
            r  <- liftIO $ readIORef (keepAliveReceiverMonitor x) 
            r' <- DP.monitor pid
            DP.unmonitor r
            liftIO $ writeIORef (keepAliveReceiverMonitor x) r'

-- | Whether the keep-alive message receiver exists.
existsKeepAliveReceiver :: KeepAliveManager -> DP.ProcessId -> IO Bool
existsKeepAliveReceiver manager pid =
  readIORef (keepAliveReceivers manager) >>=
  return . M.member pid

-- | Try to send a keep-alive message.
trySendKeepAlive :: KeepAliveManager -> DP.Process ()
trySendKeepAlive manager =
  do empty <- liftIO $ fmap M.null $ readIORef (keepAliveReceivers manager)
     unless empty $ 
       do utc <- liftIO getCurrentTime
          trySendKeepAliveUTC manager utc

-- | Try to send a keep-alive message by the specified current time.
trySendKeepAliveUTC :: KeepAliveManager -> UTCTime -> DP.Process ()
trySendKeepAliveUTC manager utc =
  do empty <- liftIO $ fmap M.null $ readIORef (keepAliveReceivers manager)
     unless empty $ 
       do f <- liftIO $ shouldSendKeepAlive manager utc
          when f $
            do ---
               logKeepAliveManager manager INFO $
                 "Sending a keep-alive message"
               ---
               liftIO $ writeIORef (keepAliveTimestamp manager) utc
               rs <- liftIO $ readIORef (keepAliveReceivers manager)
               forM_ rs $ \r ->
                 let pid = keepAliveReceiverProcess r
                 in DP.send pid KeepAliveMessage

-- | Whether should send a keep-alive message.
shouldSendKeepAlive :: KeepAliveManager -> UTCTime -> IO Bool
shouldSendKeepAlive manager utc =
  do utc0 <- readIORef (keepAliveTimestamp manager)
     let dt = fromRational $ toRational (diffUTCTime utc utc0)
     return $
       secondsToMicroseconds dt > (keepAliveInterval $ keepAliveParams manager)

-- | Convert seconds to microseconds.
secondsToMicroseconds :: Double -> Int
secondsToMicroseconds x = fromInteger $ toInteger $ round (1000000 * x)
  
-- | Log the message with the specified priority.
logKeepAliveManager :: KeepAliveManager -> Priority -> String -> DP.Process ()
{-# INLINE logKeepAliveManager #-}
logKeepAliveManager manager p message =
  when (keepAliveLoggingPriority (keepAliveParams manager) <= p) $
  DP.say $
  embracePriority p ++ " " ++ message
