
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
        TimeServerEnv(..),
        TimeServerStrategy(..),
        defaultTimeServerParams,
        defaultTimeServerEnv,
        timeServer,
        timeServerWithEnv,
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
import Simulation.Aivika.Distributed.Optimistic.State

-- | The time server parameters.
data TimeServerParams =
  TimeServerParams { tsLoggingPriority :: Priority,
                     -- ^ the logging priority
                     tsName :: String,
                     -- ^ the monitoring name of the time server
                     tsReceiveTimeout :: Int,
                     -- ^ the timeout in microseconds used when receiving messages
                     tsTimeSyncTimeout :: Int,
                     -- ^ the timeout in microseconds used for the time synchronization sessions
                     tsTimeSyncDelay :: Int,
                     -- ^ the delay in microseconds between the time synchronization sessions
                     tsProcessMonitoringEnabled :: Bool,
                     -- ^ whether the process monitoring is enabled
                     tsProcessMonitoringDelay :: Int,
                     -- ^ The delay in microseconds which must be applied for monitoring every remote process
                     tsProcessReconnectingEnabled :: Bool,
                     -- ^ whether the automatic reconnecting to processes is enabled when enabled monitoring
                     tsProcessReconnectingDelay :: Int,
                     -- ^ the delay in microseconds before reconnecting
                     tsSimulationMonitoringInterval :: Int,
                     -- ^ the interval in microseconds between sending the simulation monitoring messages
                     tsSimulationMonitoringTimeout :: Int,
                     -- ^ the timeout in microseconds when processing the simulation monitoring messages
                     tsStrategy :: TimeServerStrategy
                     -- ^ the time server strategy
                   } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TimeServerParams

-- | Those time server environment parameters that cannot be serialized and passed to another process via the net.
data TimeServerEnv =
  TimeServerEnv { tsSimulationMonitoringAction :: Maybe (TimeServerState -> DP.Process ())
                  -- ^ the simulation monitoring action
                }

-- | The time server strategy.
data TimeServerStrategy = WaitIndefinitelyForLogicalProcess
                          -- ^ wait for the logical process forever
                        | TerminateDueToLogicalProcessTimeout Int
                          -- ^ terminate the server due to the exceeded logical process timeout in microseconds,
                          -- but not less than 'tsTimeSyncTimeout', which is a much more preferable option than
                          -- significantly more risky 'UnregisterLogicalProcessDueToTimeout'
                        | UnregisterLogicalProcessDueToTimeout Int
                          -- ^ unregister the logical process due to the exceeded timeout in microseconds,
                          -- but not less than 'tsTimeSyncTimeout', which is a very risky option as there can be
                          -- un-acknowledged messages by the just unregistered logical process that might shutdown,
                          -- which would keep the global virtual time on the same value even if the existent
                          -- logical processes had another local time
                        deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TimeServerStrategy

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
               tsTerminated :: IORef Bool,
               -- ^ whether the server is terminated
               tsProcesses :: IORef (M.Map DP.ProcessId LogicalProcessInfo),
               -- ^ the information about logical processes
               tsProcessesInFind :: IORef (S.Set DP.ProcessId),
               -- ^ the processed used in the current finding of the global time
               tsGlobalTime :: IORef (Maybe Double),
               -- ^ the global time of the model
               tsGlobalTimeTimestamp :: IORef (Maybe UTCTime),
               -- ^ the global time timestamp
               tsLogicalProcessValidationTimestamp :: IORef UTCTime
               -- ^ the logical process validation timestamp
             }

-- | The information about the logical process.
data LogicalProcessInfo =
  LogicalProcessInfo { lpId :: DP.ProcessId,
                       -- ^ the logical process identifier
                       lpLocalTime :: IORef (Maybe Double),
                       -- ^ the local time of the process
                       lpTimestamp :: IORef UTCTime,
                       -- ^ the logical process timestamp
                       lpMonitorRef :: Maybe DP.MonitorRef
                       -- ^ the logical process monitor reference
                     }

-- | The default time server parameters.
defaultTimeServerParams :: TimeServerParams
defaultTimeServerParams =
  TimeServerParams { tsLoggingPriority = WARNING,
                     tsName = "Time Server",
                     tsReceiveTimeout = 100000,
                     tsTimeSyncTimeout = 60000000,
                     tsTimeSyncDelay = 100000,
                     tsProcessMonitoringEnabled = False,
                     tsProcessMonitoringDelay = 3000000,
                     tsProcessReconnectingEnabled = False,
                     tsProcessReconnectingDelay = 5000000,
                     tsSimulationMonitoringInterval = 30000000,
                     tsSimulationMonitoringTimeout = 100000,
                     tsStrategy = TerminateDueToLogicalProcessTimeout 300000000
                   }

-- | The default time server environment parameters.
defaultTimeServerEnv :: TimeServerEnv
defaultTimeServerEnv =
  TimeServerEnv { tsSimulationMonitoringAction = Nothing }

-- | Create a new time server by the specified initial quorum and parameters.
newTimeServer :: Int -> TimeServerParams -> IO TimeServer
newTimeServer n ps =
  do f  <- newIORef True
     ft <- newIORef False
     fe <- newIORef False
     m  <- newIORef M.empty
     s  <- newIORef S.empty
     t0 <- newIORef Nothing
     t' <- newIORef Nothing
     t2 <- getCurrentTime >>= newIORef
     return TimeServer { tsParams = ps,
                         tsInitQuorum = n,
                         tsInInit = f,
                         tsTerminating = ft,
                         tsTerminated = fe,
                         tsProcesses = m,
                         tsProcessesInFind = s,
                         tsGlobalTime = t0,
                         tsGlobalTimeTimestamp = t',
                         tsLogicalProcessValidationTimestamp = t2
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
            utc <- getCurrentTime >>= newIORef
            modifyIORef (tsProcesses server) $
              M.insert pid LogicalProcessInfo { lpId = pid, lpLocalTime = t, lpTimestamp = utc, lpMonitorRef = Nothing }
            return $
              do when (tsProcessMonitoringEnabled $ tsParams server) $
                   do logTimeServer server INFO $
                        "Time Server: monitoring the process by identifier " ++ show pid
                      r <- DP.monitor pid
                      liftIO $
                        modifyIORef (tsProcesses server) $
                        M.update (\x -> Just x { lpMonitorRef = Just r }) pid
                 serverId <- DP.getSelfPid
                 DP.send pid (RegisterLogicalProcessAcknowledgementMessage serverId)
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
                 DP.send pid (UnregisterLogicalProcessAcknowledgementMessage serverId)
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
                 DP.send pid (TerminateTimeServerAcknowledgementMessage serverId)
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
         do utc <- getCurrentTime
            writeIORef (lpLocalTime x) (Just t')
            writeIORef (lpTimestamp x) utc
            modifyIORef (tsProcessesInFind server) $
              S.delete pid
            return $
              tryProvideTimeServerGlobalTime server
processTimeServerMessage server (ComputeLocalTimeAcknowledgementMessage pid) =
  join $ liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing ->
         return $
         do logTimeServer server WARNING $
              "Time Server: unknown process identifier " ++ show pid
            processTimeServerMessage server (RegisterLogicalProcessMessage pid)
            processTimeServerMessage server (ComputeLocalTimeAcknowledgementMessage pid)
       Just x  ->
         do utc <- getCurrentTime
            writeIORef (lpTimestamp x) utc
            return $
              return ()
processTimeServerMessage server (ProvideTimeServerStateMessage pid) =
  do let ps   = tsParams server
         name = tsName ps
     serverId <- DP.getSelfPid
     t <- liftIO $ readIORef (tsGlobalTime server)
     m <- liftIO $ readIORef (tsProcesses server)
     let msg = TimeServerState { tsStateId = serverId,
                                 tsStateName = name,
                                 tsStateGlobalVirtualTime = t,
                                 tsStateLogicalProcesses = M.keys m }
     DP.send pid msg
processTimeServerMessage server (ReMonitorTimeServerMessage pids) =
  do forM_ pids $ \pid ->
       do m <- liftIO $ readIORef (tsProcesses server)
          case M.lookup pid m of
            Nothing ->
              logTimeServer server WARNING $
              "Time Server: unknown process identifier " ++ show pid
            Just x  ->
              case lpMonitorRef x of
                Nothing ->
                  logTimeServer server WARNING $
                  "Time Server: there is no monitor reference to " ++ show pid
                Just r  ->
                  do logTimeServer server INFO $
                       "Time Server: re-monitoring the process by identifier " ++ show pid
                     r' <- DP.monitor pid
                     DP.unmonitor r
                     liftIO $
                       modifyIORef (tsProcesses server) $
                       M.update (\x -> Just x { lpMonitorRef = Just r' }) pid
                     logTimeServer server NOTICE $
                       "Time Server: started re-monitoring " ++ show pid
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

-- | Return a logical process with the minimal timestamp.
minTimestampLogicalProcess :: TimeServer -> IO (Maybe LogicalProcessInfo)
minTimestampLogicalProcess server =
  do zs <- fmap M.assocs $ readIORef (tsProcesses server)
     case zs of
       [] -> return Nothing
       ((pid, x) : zs') -> loop zs x
         where loop [] acc = return (Just acc)
               loop ((pid, x) : zs') acc =
                 do t0 <- readIORef (lpTimestamp acc)
                    t  <- readIORef (lpTimestamp x)
                    if t0 <= t
                      then loop zs' acc
                      else loop zs' x

-- | Filter the logical processes.
filterLogicalProcesses :: TimeServer -> [DP.ProcessId] -> IO [DP.ProcessId]
filterLogicalProcesses server pids =
  do xs <- readIORef (tsProcesses server)
     return $ filter (\pid -> M.member pid xs) pids

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
     logTimeServer server ERROR $ "Exception occurred: " ++ show e
     ---
     C.throwM e

-- | Start the time server by the specified initial quorum and parameters.
-- The quorum defines the number of logical processes that must be registered in
-- the time server before the global time synchronization is started.
timeServer :: Int -> TimeServerParams -> DP.Process ()
timeServer n ps = timeServerWithEnv n ps defaultTimeServerEnv

-- | A full version of 'timeServer' that allows specifying the environment parameters.
timeServerWithEnv :: Int -> TimeServerParams -> TimeServerEnv -> DP.Process ()
timeServerWithEnv n ps env =
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
              validation <- liftIO $ readIORef (tsLogicalProcessValidationTimestamp server)
              timestamp <- liftIO $ readIORef (tsGlobalTimeTimestamp server)
              when (timeSyncTimeoutExceeded server validation utc) $
                validateLogicalProcesses server utc
              case timestamp of
                Just x | timeSyncTimeoutExceeded server x utc ->
                  resetComputingTimeServerGlobalTime server
                _ -> return ()
              if timeSyncDelayExceeded server utc0 utc
                then do tryComputeTimeServerGlobalTime server
                        loop utc
                else loop utc0
         loop' utc0 =
           C.finally
           (loop utc0)
           (liftIO $
            atomicWriteIORef (tsTerminated server) True)
     case tsSimulationMonitoringAction env of
       Nothing  -> return ()
       Just act ->
         do serverId  <- DP.getSelfPid
            monitorId <-
              DP.spawnLocal $
              let loop =
                    do f <- liftIO $ readIORef (tsTerminated server)
                       unless f $
                         do x <- DP.expectTimeout (tsSimulationMonitoringTimeout ps)
                            case x of
                              Nothing -> return ()
                              Just st -> act st
                            loop
              in C.catch loop (handleTimeServerException server)
            DP.spawnLocal $
              let loop =
                    do f <- liftIO $ readIORef (tsTerminated server)
                       unless f $
                         do liftIO $
                              threadDelay (tsSimulationMonitoringInterval ps)
                            DP.send serverId (ProvideTimeServerStateMessage monitorId)
                            loop
              in C.catch loop (handleTimeServerException server)
            return ()
     C.catch (liftIO getCurrentTime >>= loop') (handleTimeServerException server) 

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
          pids <- loop [pid0] >>= (liftIO . filterLogicalProcesses server)
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

-- | Test whether the sychronization delay has been exceeded.
timeSyncDelayExceeded :: TimeServer -> UTCTime -> UTCTime -> Bool
timeSyncDelayExceeded server utc0 utc =
  let dt = fromRational $ toRational (diffUTCTime utc utc0)
  in secondsToMicroseconds dt > (tsTimeSyncDelay $ tsParams server)

-- | Test whether the synchronization timeout has been exceeded.
timeSyncTimeoutExceeded :: TimeServer -> UTCTime -> UTCTime -> Bool
timeSyncTimeoutExceeded server utc0 utc =
  let dt = fromRational $ toRational (diffUTCTime utc utc0)
  in secondsToMicroseconds dt > (tsTimeSyncTimeout $ tsParams server)

-- | Get the difference between the specified time and the logical process timestamp.
diffLogicalProcessTimestamp :: UTCTime -> LogicalProcessInfo -> IO Int
diffLogicalProcessTimestamp utc lp =
  do utc0 <- readIORef (lpTimestamp lp)
     let dt = fromRational $ toRational (diffUTCTime utc utc0)
     return $ secondsToMicroseconds dt

-- | Validate the logical processes.
validateLogicalProcesses :: TimeServer -> UTCTime -> DP.Process ()
validateLogicalProcesses server utc =
  do logTimeServer server NOTICE $
       "Time Server: validating the logical processes"
     liftIO $
       writeIORef (tsLogicalProcessValidationTimestamp server) utc
     case tsStrategy (tsParams server) of
       WaitIndefinitelyForLogicalProcess ->
         return ()
       TerminateDueToLogicalProcessTimeout timeout ->
         do x <- liftIO $ minTimestampLogicalProcess server
            case x of
              Just lp ->
                do diff <- liftIO $ diffLogicalProcessTimestamp utc lp
                   when (diff > timeout) $
                     do logTimeServer server WARNING $
                          "Time Server: terminating due to the exceeded logical process timeout"
                        DP.terminate
              Nothing ->
                return ()
       UnregisterLogicalProcessDueToTimeout timeout ->
         do x <- liftIO $ minTimestampLogicalProcess server
            case x of
              Just lp ->
                do diff <- liftIO $ diffLogicalProcessTimestamp utc lp
                   when (diff > timeout) $
                     do logTimeServer server WARNING $
                          "Time Server: unregistering the logical process due to the exceeded timeout"
                        processTimeServerMessage server (UnregisterLogicalProcessMessage $ lpId lp)
              Nothing ->
                return ()

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
