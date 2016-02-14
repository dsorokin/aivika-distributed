
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
        spawnTimeServer) where

import qualified Data.Map as M
import Data.Maybe

import Control.Monad
import Control.Monad.Trans
import Control.Concurrent.STM
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Message

-- | The time server parameters.
data TimeServerParams = TimeServerParams

-- | The time server.
data TimeServer =
  TimeServer { tsProcesses :: TVar (M.Map DP.ProcessId LocalProcessInfo),
               -- ^ the information about local processes
               tsGlobalTime :: TVar (Maybe Double),
               -- ^ the global time of the model
               tsGlobalTimeInvalid :: TVar Bool
               -- ^ whether the global time is invalid
             }

-- | The information about the local process.
data LocalProcessInfo =
  LocalProcessInfo { lpLocalTime :: TVar (Maybe Double),
                     -- ^ the local time of the process
                     lpSentGlobalTime :: TVar (Maybe Double)
                     -- ^ the global time sent to the process for the last time
                   }

-- | The default time server parameters.
defaultTimeServerParams :: TimeServerParams
defaultTimeServerParams = TimeServerParams

-- | Process the time server message.
processTimeServerMessage :: TimeServer -> TimeServerMessage -> DP.Process ()
processTimeServerMessage server (RegisterLocalProcessMessage pid) =
  liftIO $
  atomically $
  do t1 <- newTVar Nothing
     t2 <- newTVar Nothing
     writeTVar (tsGlobalTimeInvalid server) True
     modifyTVar (tsProcesses server) $
       M.insert pid LocalProcessInfo { lpLocalTime = t1, lpSentGlobalTime = t2 }
processTimeServerMessage server (UnregisterLocalProcessMessage pid) =
  liftIO $
  atomically $
  do m <- readTVar (tsProcesses server)
     case M.lookup pid m of
       Nothing -> return ()
       Just x  ->
         do t0 <- readTVar (tsGlobalTime server) 
            t  <- readTVar (lpLocalTime x)
            when (t0 == t) $
              writeTVar (tsGlobalTimeInvalid server) True
            writeTVar (tsProcesses server) $
              M.delete pid m
processTimeServerMessage server (TerminateTimeServerMessage pid) =
  do pids <-
       liftIO $
       atomically $
       do m <- readTVar (tsProcesses server)
          writeTVar (tsProcesses server) M.empty
          writeTVar (tsGlobalTime server) Nothing
          writeTVar (tsGlobalTimeInvalid server) False
          return (M.keys m)
     forM_ pids $ \pid ->
       DP.send pid TerminateLocalProcessMessage
processTimeServerMessage server (GlobalTimeMessageResp pid t') =
  liftIO $
  atomically $
  do m <- readTVar (tsProcesses server)
     case M.lookup pid m of
       Nothing -> return ()
       Just x  ->
         do t0 <- readTVar (tsGlobalTime server)
            t  <- readTVar (lpLocalTime x)
            when (t /= Just t') $
              do writeTVar (lpLocalTime x) (Just t')
                 when (t0 == t) $
                   writeTVar (tsGlobalTimeInvalid server) True
processTimeServerMessage server (LocalTimeMessage pid t') =
  do t0 <- liftIO $
           atomically $
           do m <- readTVar (tsProcesses server)
              case M.lookup pid m of
                Nothing -> return Nothing
                Just x  ->
                  do t0 <- readTVar (tsGlobalTime server)
                     t  <- readTVar (lpLocalTime x)
                     if t == Just t'
                       then return Nothing
                       else do writeTVar (lpLocalTime x) (Just t')
                               when (t0 == t) $
                                 writeTVar (tsGlobalTimeInvalid server) True
                               t0' <- readTVar (lpSentGlobalTime x)
                               if (t0 == t0') || (isNothing t0)
                                 then return Nothing
                                 else do writeTVar (lpSentGlobalTime x) t0
                                         return t0
     case t0 of
       Nothing -> return ()
       Just t0 ->
         DP.send pid (LocalTimeMessageResp t0)

-- | Spawn a new time server with the specified parameters.
spawnTimeServer :: DP.NodeId -> TimeServerParams -> DP.Process DP.ProcessId
spawnTimeServer = undefined
