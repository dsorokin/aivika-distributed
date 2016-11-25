
{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
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
        timeServer) where

import qualified Data.Map as M
import qualified Data.Set as S
import Data.Maybe
import Data.IORef
import Data.Typeable
import Data.Binary

import GHC.Generics

import Control.Monad
import Control.Monad.Trans
import Control.Concurrent
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.Message

-- | The time server parameters.
data TimeServerParams =
  TimeServerParams { tsLoggingPriority :: Priority,
                     -- ^ the logging priority
                     tsExpectTimeout :: Int,
                     -- ^ the timeout in microseconds within which a new message is expected
                     tsTimeSyncDelay :: Int
                     -- ^ the further delay in microseconds before the time synchronization
                   } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TimeServerParams

-- | The time server.
data TimeServer =
  TimeServer { tsParams :: TimeServerParams,
               -- ^ the time server parameters
               tsInitQuorum :: Int,
               -- ^ the initial quorum of registered local processes to start the simulation
               tsInInit :: IORef Bool,
               -- ^ whether the time server is in the initial mode
               tsProcesses :: IORef (M.Map DP.ProcessId LocalProcessInfo),
               -- ^ the information about local processes
               tsProcessesInFind :: IORef (S.Set DP.ProcessId),
               -- ^ the processed used in the current finding of the global time
               tsGlobalTime :: IORef (Maybe Double)
               -- ^ the global time of the model
             }

-- | The information about the local process.
data LocalProcessInfo =
  LocalProcessInfo { lpLocalTime :: IORef (Maybe Double)
                     -- ^ the local time of the process
                   }

-- | The default time server parameters.
defaultTimeServerParams :: TimeServerParams
defaultTimeServerParams =
  TimeServerParams { tsLoggingPriority = WARNING,
                     tsExpectTimeout = 1000,
                     tsTimeSyncDelay = 1000
                   }

-- | Create a new time server by the specified initial quorum and parameters.
newTimeServer :: Int -> TimeServerParams -> IO TimeServer
newTimeServer n ps =
  do f  <- newIORef False
     m  <- newIORef M.empty
     s  <- newIORef S.empty
     t0 <- newIORef Nothing
     return TimeServer { tsParams = ps,
                         tsInitQuorum = n,
                         tsInInit = f,
                         tsProcesses = m,
                         tsProcessesInFind = s,
                         tsGlobalTime = t0
                       }

-- | Process the time server message.
processTimeServerMessage :: TimeServer -> TimeServerMessage -> DP.Process ()
processTimeServerMessage server (RegisterLocalProcessMessage pid) =
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
              M.insert pid LocalProcessInfo { lpLocalTime = t }
            return $
              tryStartTimeServer server
processTimeServerMessage server (UnregisterLocalProcessMessage pid) =
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
              tryProvideTimeServerGlobalTime server
processTimeServerMessage server (TerminateTimeServerMessage pid) =
  do pids <-
       liftIO $
       do m <- readIORef (tsProcesses server)
          writeIORef (tsProcesses server) M.empty
          writeIORef (tsProcessesInFind server) S.empty
          writeIORef (tsGlobalTime server) Nothing
          return $ filter (/= pid) (M.keys m)
     forM_ pids $ \pid ->
       DP.send pid TerminateLocalProcessMessage
     logTimeServer server INFO "Time Server: terminating..."
     DP.terminate
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
            processTimeServerMessage server (RegisterLocalProcessMessage pid)
            processTimeServerMessage server (LocalTimeMessage pid t')
       Just x  ->
         do writeIORef (lpLocalTime x) (Just t')
            modifyIORef (tsProcessesInFind server) $
              S.delete pid
            return $
              tryProvideTimeServerGlobalTime server

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
                           tryComputeTimeServerGlobalTime server
  
-- | Try to compute the global time and provide the local processes with it.
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

-- | Try to provide the local processes wth the global time. 
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
  do zs <- liftIO $ fmap M.assocs $ readIORef (tsProcesses server)
     forM_ zs $ \(pid, x) ->
       liftIO $
       modifyIORef (tsProcessesInFind server) $
       S.insert pid
     forM_ zs $ \(pid, x) ->
       DP.send pid ComputeLocalTimeMessage

-- | Provide the local processes with the global time.
provideTimeServerGlobalTime :: TimeServer -> DP.Process ()
provideTimeServerGlobalTime server =
  do t0 <- liftIO $ timeServerGlobalTime server
     case t0 of
       Nothing -> return ()
       Just t0 ->
         do t' <- liftIO $ readIORef (tsGlobalTime server)
            when (t' .>. Just t0) $
              logTimeServer server NOTICE
              "Time Server: the global time has decreased"
            liftIO $ writeIORef (tsGlobalTime server) (Just t0)
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

-- | Start the time server by the specified initial quorum and parameters.
-- The quorum defines the number of local processes that must be registered in
-- the time server before the global time synchronization is started.
timeServer :: Int -> TimeServerParams -> DP.Process ()
timeServer n ps =
  do server <- liftIO $ newTimeServer n ps
     logTimeServer server INFO "Time Server: starting..."
     forever $
       do m <- DP.expectTimeout (tsExpectTimeout ps) :: DP.Process (Maybe TimeServerMessage)
          case m of
            Nothing -> return ()
            Just m  ->
              do ---
                 logTimeServer server DEBUG $
                   "Time Server: " ++ show m
                 ---
                 processTimeServerMessage server m
          liftIO $
            threadDelay (tsTimeSyncDelay ps)
          tryComputeTimeServerGlobalTime server

-- | Log the message with the specified priority.
logTimeServer :: TimeServer -> Priority -> String -> DP.Process ()
{-# INLINE logTimeServer #-}
logTimeServer server p message =
  when (tsLoggingPriority (tsParams server) <= p) $
  DP.say $
  embracePriority p ++ " " ++ message
