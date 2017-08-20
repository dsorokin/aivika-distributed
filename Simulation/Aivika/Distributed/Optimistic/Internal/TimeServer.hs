
{-# LANGUAGE DeriveGeneric, DeriveDataTypeable #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module allows running the time server that coordinates the global simulation time.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
       (TimeServerParams(..),
        defaultTimeServerParams,
        timeServer,
        curryTimeServer) where

import qualified Data.Map as M
import qualified Data.Set as S
import Data.Maybe
import Data.IORef
import Data.Typeable
import Data.Binary
import Data.Time.Clock

import GHC.Generics

import Control.Monad
import Control.Monad.Trans
import Control.Exception
import qualified Control.Monad.Catch as C
import Control.Concurrent
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.Message

-- | The time server parameters.
data TimeServerParams =
  TimeServerParams { tsLoggingPriority :: Priority,
                     -- ^ the logging priority
                     tsReceiveTimeout :: Int,
                     -- ^ the timeout in microseconds used when receiving messages
                     tsTimeSyncTimeout :: Int,
                     -- ^ the timeout in microseconds used for the time synchronization sessions
                     tsTimeSyncDelay :: Int,
                     -- ^ the delay in microseconds between the time synchronization sessions
                     tsProcessMonitoringEnabled :: Bool,
                     -- ^ Whether the process monitoring is enabled
                     tsProcessMonitoringDelay :: Int,
                     -- ^ The delay in microseconds which must be applied for monitoring every remote process.
                     tsProcessReconnectingEnabled :: Bool,
                     -- ^ Whether the automatic reconnecting to processes is enabled when enabled monitoring
                     tsProcessReconnectingDelay :: Int
                     -- ^ the delay in microseconds before reconnecting
                   } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TimeServerParams

-- | The time server.
data TimeServer =
  TimeServer { tsParams :: TimeServerParams,
               -- ^ the time server parameters
               tsInitQuorum :: Int,
               -- ^ the initial quorum of registered logical processes to start the simulation
               tsInInit :: IORef Bool,
               -- ^ whether the time server is in the initial mode
               tsTerminating :: IORef Bool,
               -- ^ whether the time server is in the terminating mode
               tsProcesses :: IORef (M.Map DP.ProcessId LogicalProcessInfo),
               -- ^ the information about logical processes
               tsProcessesInFind :: IORef (S.Set DP.ProcessId),
               -- ^ the processed used in the current finding of the global time
               tsGlobalTime :: IORef (Maybe Double),
               -- ^ the global time of the model
               tsGlobalTimeTimestamp :: IORef (Maybe UTCTime)
               -- ^ the global time timestamp
             }

-- | The information about the logical process.
data LogicalProcessInfo =
  LogicalProcessInfo { lpLocalTime :: IORef (Maybe Double),
                       -- ^ the local time of the process
                       lpMonitorRef :: Maybe DP.MonitorRef
                       -- ^ the logical process monitor reference
                     }

-- | The default time server parameters.
defaultTimeServerParams :: TimeServerParams
defaultTimeServerParams =
  TimeServerParams { tsLoggingPriority = WARNING,
                     tsReceiveTimeout = 100000,
                     tsTimeSyncTimeout = 60000000,
                     tsTimeSyncDelay = 1000000,
                     tsProcessMonitoringEnabled = False,
                     tsProcessMonitoringDelay = 3000000,
                     tsProcessReconnectingEnabled = False,
                     tsProcessReconnectingDelay = 5000000
                   }

-- | Create a new time server by the specified initial quorum and parameters.
newTimeServer :: Int -> TimeServerParams -> IO TimeServer
newTimeServer n ps =
  do f  <- newIORef True
     ft <- newIORef False
     m  <- newIORef M.empty
     s  <- newIORef S.empty
     t0 <- newIORef Nothing
     t' <- newIORef Nothing
     return TimeServer { tsParams = ps,
                         tsInitQuorum = n,
                         tsInInit = f,
                         tsTerminating = ft,
                         tsProcesses = m,
                         tsProcessesInFind = s,
                         tsGlobalTime = t0,
                         tsGlobalTimeTimestamp = t'
                       }

-- | Process the time server message.
processTimeServerMessage :: TimeServer -> TimeServerMessage -> DP.Process ()
processTimeServerMessage server (RegisterLogicalProcessMessage pid) =
  join $ liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Just x ->
         return $
         logTimeServer server WARNING $
         "Time Server: already registered process identifier " ++ show pid
       Nothing  ->
         do t <- newIORef Nothing
            modifyIORef (tsProcesses server) $
              M.insert pid LogicalProcessInfo { lpLocalTime = t, lpMonitorRef = Nothing }
            return $
              do when (tsProcessMonitoringEnabled $ tsParams server) $
                   do logTimeServer server INFO $
                        "Time Server: monitoring the process by identifier " ++ show pid
                      r <- DP.monitor pid
                      liftIO $
                        modifyIORef (tsProcesses server) $
                        M.update (\x -> Just x { lpMonitorRef = Just r }) pid
                 serverId <- DP.getSelfPid
                 DP.send pid (RegisterLogicalProcessAcknowledgmentMessage serverId)
                 tryStartTimeServer server
processTimeServerMessage server (UnregisterLogicalProcessMessage pid) =
  join $ liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing ->
         return $
         logTimeServer server WARNING $
         "Time Server: unknown process identifier " ++ show pid
       Just x  ->
         do modifyIORef (tsProcesses server) $
              M.delete pid
            modifyIORef (tsProcessesInFind server) $
              S.delete pid
            return $
              do when (tsProcessMonitoringEnabled $ tsParams server) $
                   case lpMonitorRef x of
                     Nothing -> return ()
                     Just r  ->
                       do logTimeServer server INFO $
                            "Time Server: unmonitoring the process by identifier " ++ show pid
                          DP.unmonitor r
                 serverId <- DP.getSelfPid
                 DP.send pid (UnregisterLogicalProcessAcknowledgmentMessage serverId)
                 tryProvideTimeServerGlobalTime server
                 tryTerminateTimeServer server
processTimeServerMessage server (TerminateTimeServerMessage pid) =
  join $ liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing ->
         return $
         logTimeServer server WARNING $
         "Time Server: unknown process identifier " ++ show pid
       Just x  ->
         do modifyIORef (tsProcesses server) $
              M.delete pid
            modifyIORef (tsProcessesInFind server) $
              S.delete pid
            return $
              do when (tsProcessMonitoringEnabled $ tsParams server) $
                   case lpMonitorRef x of
                     Nothing -> return ()
                     Just r  ->
                       do logTimeServer server INFO $
                            "Time Server: unmonitoring the process by identifier " ++ show pid
                          DP.unmonitor r
                 serverId <- DP.getSelfPid
                 DP.send pid (TerminateTimeServerAcknowledgmentMessage serverId)
                 startTerminatingTimeServer server
processTimeServerMessage server (RequestGlobalTimeMessage pid) =
  tryComputeTimeServerGlobalTime server
processTimeServerMessage server (LocalTimeMessage pid t') =
  join $ liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing ->
         return $
         do logTimeServer server WARNING $
              "Time Server: unknown process identifier " ++ show pid
            processTimeServerMessage server (RegisterLogicalProcessMessage pid)
            processTimeServerMessage server (LocalTimeMessage pid t')
       Just x  ->
         do writeIORef (lpLocalTime x) (Just t')
            modifyIORef (tsProcessesInFind server) $
              S.delete pid
            return $
              tryProvideTimeServerGlobalTime server
processTimeServerMessage server (ReMonitorTimeServerMessage pids) =
  do forM_ pids $ \pid ->
       do ---
          logTimeServer server NOTICE $ "Time Server: re-monitoring " ++ show pid
          ---
          DP.monitor pid
          ---
          logTimeServer server NOTICE $ "Time Server: started re-monitoring " ++ show pid
          ---
     resetComputingTimeServerGlobalTime server

-- | Whether the both values are defined and the first is greater than or equaled to the second.
(.>=.) :: Maybe Double -> Maybe Double -> Bool
(.>=.) (Just x) (Just y) = x >= y
(.>=.) _ _ = False

-- | Whether the both values are defined and the first is greater than the second.
(.>.) :: Maybe Double -> Maybe Double -> Bool
(.>.) (Just x) (Just y) = x > y
(.>.) _ _ = False

-- | Try to start synchronizing the global time.
tryStartTimeServer :: TimeServer -> DP.Process ()
tryStartTimeServer server =
  join $ liftIO $
  do f <- readIORef (tsInInit server)
     if not f
       then return $
            return ()
       else do m <- readIORef (tsProcesses server)
               if M.size m < tsInitQuorum server
                 then return $
                      return ()
                 else do writeIORef (tsInInit server) False
                         return $
                           do logTimeServer server INFO $
                                "Time Server: starting"
                              tryComputeTimeServerGlobalTime server
  
-- | Try to compute the global time and provide the logical processes with it.
tryComputeTimeServerGlobalTime :: TimeServer -> DP.Process ()
tryComputeTimeServerGlobalTime server =
  join $ liftIO $
  do f <- readIORef (tsInInit server)
     if f
       then return $
            return ()
       else do s <- readIORef (tsProcessesInFind server)
               if S.size s > 0
                 then return $
                      return ()
                 else return $
                      computeTimeServerGlobalTime server

-- | Reset computing the time server global time.
resetComputingTimeServerGlobalTime :: TimeServer -> DP.Process ()
resetComputingTimeServerGlobalTime server =
  do logTimeServer server NOTICE $
       "Time Server: reset computing the global time"
     liftIO $
       do utc <- getCurrentTime
          writeIORef (tsProcessesInFind server) S.empty
          writeIORef (tsGlobalTimeTimestamp server) (Just utc)

-- | Try to provide the logical processes wth the global time. 
tryProvideTimeServerGlobalTime :: TimeServer -> DP.Process ()
tryProvideTimeServerGlobalTime server =
  join $ liftIO $
  do f <- readIORef (tsInInit server)
     if f
       then return $
            return ()
       else do s <- readIORef (tsProcessesInFind server)
               if S.size s > 0
                 then return $
                      return ()
                 else return $
                      provideTimeServerGlobalTime server

-- | Initiate computing the global time.
computeTimeServerGlobalTime :: TimeServer -> DP.Process ()
computeTimeServerGlobalTime server =
  do logTimeServer server DEBUG $
       "Time Server: computing the global time..."
     zs <- liftIO $ fmap M.assocs $ readIORef (tsProcesses server)
     forM_ zs $ \(pid, x) ->
       liftIO $
       modifyIORef (tsProcessesInFind server) $
       S.insert pid
     forM_ zs $ \(pid, x) ->
       DP.send pid ComputeLocalTimeMessage

-- | Provide the logical processes with the global time.
provideTimeServerGlobalTime :: TimeServer -> DP.Process ()
provideTimeServerGlobalTime server =
  do t0 <- liftIO $ timeServerGlobalTime server
     logTimeServer server INFO $
       "Time Server: providing the global time = " ++ show t0
     case t0 of
       Nothing -> return ()
       Just t0 ->
         do t' <- liftIO $ readIORef (tsGlobalTime server)
            when (t' .>. Just t0) $
              logTimeServer server NOTICE
              "Time Server: the global time has decreased"
            timestamp <- liftIO getCurrentTime
            liftIO $ writeIORef (tsGlobalTime server) (Just t0)
            liftIO $ writeIORef (tsGlobalTimeTimestamp server) (Just timestamp)
            zs <- liftIO $ fmap M.assocs $ readIORef (tsProcesses server)
            forM_ zs $ \(pid, x) ->
              DP.send pid (GlobalTimeMessage t0)

-- | Return the time server global time.
timeServerGlobalTime :: TimeServer -> IO (Maybe Double)
timeServerGlobalTime server =
  do zs <- fmap M.assocs $ readIORef (tsProcesses server)
     case zs of
       [] -> return Nothing
       ((pid, x) : zs') ->
         do t <- readIORef (lpLocalTime x)
            loop zs t
              where loop [] acc = return acc
                    loop ((pid, x) : zs') acc =
                      do t <- readIORef (lpLocalTime x)
                         case t of
                           Nothing ->
                             loop zs' Nothing
                           Just _  ->
                             loop zs' (liftM2 min t acc)

-- | Start terminating the time server.
startTerminatingTimeServer :: TimeServer -> DP.Process ()
startTerminatingTimeServer server =
  do logTimeServer server INFO "Time Server: start terminating..."
     liftIO $
       writeIORef (tsTerminating server) True
     tryTerminateTimeServer server

-- | Try to terminate the time server.
tryTerminateTimeServer :: TimeServer -> DP.Process ()
tryTerminateTimeServer server =
  do f <- liftIO $ readIORef (tsTerminating server)
     when f $
       do m <- liftIO $ readIORef (tsProcesses server)
          when (M.null m) $
            do logTimeServer server INFO "Time Server: terminate"
               DP.terminate

-- | Convert seconds to microseconds.
secondsToMicroseconds :: Double -> Int
secondsToMicroseconds x = fromInteger $ toInteger $ round (1000000 * x)

-- | The internal time server message.
data InternalTimeServerMessage = InternalTimeServerMessage TimeServerMessage
                                 -- ^ the time server message
                               | InternalProcessMonitorNotification DP.ProcessMonitorNotification
                                 -- ^ the process monitor notification
                               | InternalKeepAliveMessage KeepAliveMessage
                                 -- ^ the keep alive message

-- | Handle the time server exception
handleTimeServerException :: TimeServer -> SomeException -> DP.Process ()
handleTimeServerException server e =
  do ---
     logTimeServer server ERROR $ "Exception occured: " ++ show e
     ---
     C.throwM e

-- | Start the time server by the specified initial quorum and parameters.
-- The quorum defines the number of logical processes that must be registered in
-- the time server before the global time synchronization is started.
timeServer :: Int -> TimeServerParams -> DP.Process ()
timeServer n ps =
  do server <- liftIO $ newTimeServer n ps
     logTimeServer server INFO "Time Server: starting..."
     let loop utc0 =
           do let f1 :: TimeServerMessage -> DP.Process InternalTimeServerMessage
                  f1 x = return (InternalTimeServerMessage x)
                  f2 :: DP.ProcessMonitorNotification -> DP.Process InternalTimeServerMessage
                  f2 x = return (InternalProcessMonitorNotification x)
                  f3 :: KeepAliveMessage -> DP.Process InternalTimeServerMessage
                  f3 x = return (InternalKeepAliveMessage x)
              a <- DP.receiveTimeout (tsReceiveTimeout ps) [DP.match f1, DP.match f2, DP.match f3]
              case a of
                Nothing -> return ()
                Just (InternalTimeServerMessage m) ->
                  do ---
                     logTimeServer server DEBUG $
                       "Time Server: " ++ show m
                     ---
                     processTimeServerMessage server m
                Just (InternalProcessMonitorNotification m) ->
                  handleProcessMonitorNotification m server
                Just (InternalKeepAliveMessage m) ->
                  do ---
                     logTimeServer server DEBUG $
                       "Time Server: " ++ show m
                     ---
                     return ()
              utc <- liftIO getCurrentTime
              timestamp <- liftIO $ readIORef (tsGlobalTimeTimestamp server)
              case timestamp of
                Just x | shouldResetComputingTimeServerGlobalTime server x utc ->
                  resetComputingTimeServerGlobalTime server
                _ -> return ()
              if shouldComputeTimeServerGlobalTime server utc0 utc
                then do tryComputeTimeServerGlobalTime server
                        loop utc
                else loop utc0
     C.catch (liftIO getCurrentTime >>= loop) (handleTimeServerException server) 

-- | Handle the process monitor notification.
handleProcessMonitorNotification :: DP.ProcessMonitorNotification -> TimeServer -> DP.Process ()
handleProcessMonitorNotification m@(DP.ProcessMonitorNotification _ pid0 reason) server =
  do let ps = tsParams server
         recv m@(DP.ProcessMonitorNotification _ _ _) = 
           do ---
              logTimeServer server WARNING $
                "Time Server: received a process monitor notification " ++ show m
              ---
              return m
     recv m
     when (tsProcessReconnectingEnabled ps && reason == DP.DiedDisconnect) $
       do liftIO $
            threadDelay (tsProcessReconnectingDelay ps)
          let pred m@(DP.ProcessMonitorNotification _ _ reason) = reason == DP.DiedDisconnect
              loop :: [DP.ProcessId] -> DP.Process [DP.ProcessId]
              loop acc =
                do y <- DP.receiveTimeout 0 [DP.matchIf pred recv]
                   case y of
                     Nothing -> return $ reverse acc
                     Just m@(DP.ProcessMonitorNotification _ pid _) -> loop (pid : acc)
          pids <- loop [pid0]
          ---
          logTimeServer server NOTICE "Begin reconnecting..."
          ---
          forM_ pids $ \pid ->
            do ---
               logTimeServer server NOTICE $
                 "Time Server: reconnecting to " ++ show pid
               ---
               DP.reconnect pid
          serverId <- DP.getSelfPid
          DP.spawnLocal $
            let action =
                  do liftIO $
                       threadDelay (tsProcessMonitoringDelay ps)
                     ---
                     logTimeServer server NOTICE $ "Time Server: proceed to the re-monitoring"
                     ---
                     DP.send serverId (ReMonitorTimeServerMessage pids)
            in C.catch action (handleTimeServerException server)
          return ()

-- | Test whether should compute the time server global time.
shouldComputeTimeServerGlobalTime :: TimeServer -> UTCTime -> UTCTime -> Bool
shouldComputeTimeServerGlobalTime server utc0 utc =
  let dt = fromRational $ toRational (diffUTCTime utc utc0)
  in secondsToMicroseconds dt > (tsTimeSyncDelay $ tsParams server)

-- | Test whether should reset computing the time server global time.
shouldResetComputingTimeServerGlobalTime :: TimeServer -> UTCTime -> UTCTime -> Bool
shouldResetComputingTimeServerGlobalTime server utc0 utc =
  let dt = fromRational $ toRational (diffUTCTime utc utc0)
  in secondsToMicroseconds dt > (tsTimeSyncTimeout $ tsParams server)

-- | A curried version of 'timeServer' for starting the time server on remote node.
curryTimeServer :: (Int, TimeServerParams) -> DP.Process ()
curryTimeServer (n, ps) = timeServer n ps

-- | Log the message with the specified priority.
logTimeServer :: TimeServer -> Priority -> String -> DP.Process ()
{-# INLINE logTimeServer #-}
logTimeServer server p message =
  when (tsLoggingPriority (tsParams server) <= p) $
  DP.say $
  embracePriority p ++ " " ++ message
