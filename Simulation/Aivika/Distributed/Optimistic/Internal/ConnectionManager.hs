
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.ConnectionManager
-- Copyright  : Copyright (c) 2015-2018, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module is responsible for managing the connections.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.ConnectionManager
       (ConnectionManager,
        ConnectionParams(..),
        newConnectionManager,
        tryAddMessageReceiver,
        addMessageReceiver,
        removeMessageReceiver,
        reconnectMessageReceivers,
        filterMessageReceivers,
        existsMessageReceiver,
        trySendKeepAlive,
        trySendKeepAliveUTC) where

import qualified Data.Map as M
import qualified Data.Set as S
import Data.Maybe
import Data.Either
import Data.IORef
import Data.Time.Clock
import Data.Word

import Control.Monad
import Control.Monad.Trans
import Control.Concurrent
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.Message

-- | The connection parameters.
data ConnectionParams =
  ConnectionParams { connLoggingPriority :: Priority,
                     -- ^ the logging priority
                     connKeepAliveInterval :: Int,
                     -- ^ the interval in microseconds to send keep-alive messages
                     connReconnectingDelay :: Int,
                     -- ^ the reconnecting delay in microseconds
                     connMonitoringDelay :: Int
                     -- ^ the monitoring delay in microseconds
                   }

-- | The connection manager.
data ConnectionManager =
  ConnectionManager { connParams :: ConnectionParams,
                      -- ^ the manager parameter
                      connKeepAliveTimestamp :: IORef UTCTime,
                      -- ^ the keep alive timestamp
                      connReceivers :: IORef (M.Map DP.ProcessId ConnectionMessageReceiver)
                      -- ^ the receivers of messages
                    }

-- | The connection message receiver.
data ConnectionMessageReceiver =
  ConnectionMessageReceiver { connReceiverProcess :: DP.ProcessId,
                              -- ^ the receiver of messages
                              connReceiverMonitor :: IORef (Maybe DP.MonitorRef)
                              -- ^ a monitor of the message receiver
                            }

-- | Create a new connection manager.
newConnectionManager :: ConnectionParams -> IO ConnectionManager
newConnectionManager ps =
  do timestamp <- getCurrentTime >>= newIORef
     receivers <- newIORef M.empty
     return ConnectionManager { connParams = ps,
                                connKeepAliveTimestamp = timestamp,
                                connReceivers = receivers  }

-- | Try to add the connection message receiver.
tryAddMessageReceiver :: ConnectionManager -> DP.ProcessId -> DP.Process Bool
tryAddMessageReceiver manager pid =
  do f <- liftIO $
          existsMessageReceiver manager pid
     if f
       then return False
       else do addMessageReceiver manager pid
               return True

-- | Add the connection message receiver.
addMessageReceiver :: ConnectionManager -> DP.ProcessId -> DP.Process ()
addMessageReceiver manager pid =
  do ---
     logConnectionManager manager INFO $ "Monitoring " ++ show pid
     ---
     r  <- DP.monitor pid
     r2 <- liftIO $ newIORef (Just r)
     let x = ConnectionMessageReceiver { connReceiverProcess = pid,
                                         connReceiverMonitor = r2 }
     liftIO $
       modifyIORef (connReceivers manager) $
       M.insert pid x

-- | Remove the connection message receiver.
removeMessageReceiver :: ConnectionManager -> DP.ProcessId -> DP.Process ()
removeMessageReceiver manager pid =
  do rs <- liftIO $ readIORef (connReceivers manager)
     case M.lookup pid rs of
       Nothing ->
         logConnectionManager manager WARNING $ "Could not find the monitored process " ++ show pid
       Just r  ->
         do ---
            logConnectionManager manager INFO $ "Unmonitoring " ++ show pid
            ---
            ref <- liftIO $ readIORef (connReceiverMonitor r)
            case ref of
              Just m  -> DP.unmonitor m
              Nothing ->
                logConnectionManager manager WARNING $ "Could not find the monitor reference for process " ++ show pid
            liftIO $
              modifyIORef (connReceivers manager) $
              M.delete pid

-- | Reconnect to the message receivers.
reconnectMessageReceivers :: ConnectionManager -> [DP.ProcessId] -> DP.Process ()
reconnectMessageReceivers manager pids =
  do rs <- messageReceivers manager pids
     unless (null rs) $
       do forM_ rs $
            unmonitorMessageReceiver manager
          liftIO $
            threadDelay (connReconnectingDelay $ connParams manager)
          logConnectionManager manager NOTICE "Begin reconnecting..."
          forM_ rs $
            reconnectToMessageReceiver manager
          liftIO $
            threadDelay (connMonitoringDelay $ connParams manager)
          logConnectionManager manager NOTICE "Begin remonitoring..."
          forM_ rs $
            monitorMessageReceiver manager

-- | Unmonitor the message receiver.
unmonitorMessageReceiver :: ConnectionManager -> ConnectionMessageReceiver -> DP.Process ()
unmonitorMessageReceiver manager r =
  do let pid = connReceiverProcess r
     ref <- liftIO $ readIORef (connReceiverMonitor r)
     case ref of
       Just m  ->
         do logConnectionManager manager NOTICE $ "Unmonitoring " ++ show pid
            DP.unmonitor m
            liftIO $ writeIORef (connReceiverMonitor r) Nothing
       Nothing ->
         logConnectionManager manager WARNING $ "Could not find the monitor reference for process " ++ show pid

-- | Monitor the message receiver.
monitorMessageReceiver :: ConnectionManager -> ConnectionMessageReceiver -> DP.Process ()
monitorMessageReceiver manager r =
  do let pid = connReceiverProcess r
     ref <- liftIO $ readIORef (connReceiverMonitor r)
     case ref of
       Nothing ->
         do logConnectionManager manager NOTICE $ "Monitoring " ++ show pid
            x <- DP.monitor pid
            liftIO $ writeIORef (connReceiverMonitor r) (Just x)
       Just x0 ->
         do logConnectionManager manager WARNING $ "Re-monitoring " ++ show pid
            x <- DP.monitor pid
            DP.unmonitor x0
            liftIO $ writeIORef (connReceiverMonitor r) (Just x)

-- | Reconnect to the message receiver.
reconnectToMessageReceiver :: ConnectionManager -> ConnectionMessageReceiver -> DP.Process ()
reconnectToMessageReceiver manager r =
  do let pid = connReceiverProcess r
     logConnectionManager manager NOTICE $ "Direct reconnecting to " ++ show pid
     DP.reconnect pid

-- | Whether the connection message receiver exists.
existsMessageReceiver :: ConnectionManager -> DP.ProcessId -> IO Bool
existsMessageReceiver manager pid =
  readIORef (connReceivers manager) >>=
  return . M.member pid

-- | Try to send keep-alive messages.
trySendKeepAlive :: ConnectionManager -> DP.Process ()
trySendKeepAlive manager =
  do empty <- liftIO $ fmap M.null $ readIORef (connReceivers manager)
     unless empty $ 
       do utc <- liftIO getCurrentTime
          trySendKeepAliveUTC manager utc

-- | Try to send keep-alive messages by the specified current time.
trySendKeepAliveUTC :: ConnectionManager -> UTCTime -> DP.Process ()
trySendKeepAliveUTC manager utc =
  do empty <- liftIO $ fmap M.null $ readIORef (connReceivers manager)
     unless empty $ 
       do f <- liftIO $ shouldSendKeepAlive manager utc
          when f $
            do ---
               logConnectionManager manager INFO $
                 "Sending keep-alive messages"
               ---
               liftIO $ writeIORef (connKeepAliveTimestamp manager) utc
               rs <- liftIO $ readIORef (connReceivers manager)
               forM_ rs $ \r ->
                 do let pid = connReceiverProcess r
                    DP.send pid KeepAliveMessage

-- | Whether should send a keep-alive message.
shouldSendKeepAlive :: ConnectionManager -> UTCTime -> IO Bool
shouldSendKeepAlive manager utc =
  do utc0 <- readIORef (connKeepAliveTimestamp manager)
     let dt = fromRational $ toRational (diffUTCTime utc utc0)
     return $
       secondsToMicroseconds dt > (connKeepAliveInterval $ connParams manager)

-- | Convert seconds to microseconds.
secondsToMicroseconds :: Double -> Int
secondsToMicroseconds x = fromInteger $ toInteger $ round (1000000 * x)

-- | Get the connection message receivers.
messageReceivers :: ConnectionManager -> [DP.ProcessId] -> DP.Process [ConnectionMessageReceiver]
messageReceivers manager pids =
  do rs <- liftIO $ readIORef (connReceivers manager)
     fmap mconcat $
       forM pids $ \pid ->
       case M.lookup pid rs of
         Just x  -> return [x]
         Nothing ->
           do logConnectionManager manager WARNING $ "Could not find the monitored process " ++ show pid
              return []

-- | Filter the message receivers.
filterMessageReceivers :: ConnectionManager -> [DP.ProcessMonitorNotification] -> DP.Process [DP.ProcessId]
filterMessageReceivers manager ms =
  do rs <- liftIO $ readIORef (connReceivers manager)
     fmap (S.toList . S.fromList . mconcat) $
       forM ms $ \(DP.ProcessMonitorNotification ref pid _) ->
       case M.lookup pid rs of
         Nothing ->
           do logConnectionManager manager WARNING $ "Could not find the monitored process " ++ show pid
              return []
         Just x  ->
           do ref0 <- liftIO $ readIORef (connReceiverMonitor x)
              if ref0 == Just ref
                then return [pid]
                else do logConnectionManager manager NOTICE $ "Received the old monitor reference for process " ++ show pid
                        return []

-- | Log the message with the specified priority.
logConnectionManager :: ConnectionManager -> Priority -> String -> DP.Process ()
{-# INLINE logConnectionManager #-}
logConnectionManager manager p message =
  when (connLoggingPriority (connParams manager) <= p) $
  DP.say $
  embracePriority p ++ " " ++ message
