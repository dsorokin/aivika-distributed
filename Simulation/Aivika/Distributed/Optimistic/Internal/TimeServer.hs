
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
import Data.IORef

import Control.Monad
import Control.Monad.Trans
import qualified Control.Distributed.Process as DP

import Simulation.Aivika.Distributed.Optimistic.Internal.Message

-- | The time server parameters.
data TimeServerParams = TimeServerParams

-- | The time server.
data TimeServer =
  TimeServer { tsProcesses :: IORef (M.Map DP.ProcessId LocalProcessInfo),
               -- ^ the information about local processes
               tsGlobalTime :: IORef (Maybe Double),
               -- ^ the global time of the model
               tsGlobalTimeInvalid :: IORef Bool
               -- ^ whether the global time is invalid
             }

-- | The information about the local process.
data LocalProcessInfo =
  LocalProcessInfo { lpLocalTime :: IORef (Maybe Double),
                     -- ^ the local time of the process
                     lpSentGlobalTime :: IORef (Maybe Double)
                     -- ^ the global time sent to the process for the last time
                   }

-- | The default time server parameters.
defaultTimeServerParams :: TimeServerParams
defaultTimeServerParams = TimeServerParams

-- | Process the time server message.
processTimeServerMessage :: TimeServer -> TimeServerMessage -> DP.Process ()
processTimeServerMessage server (RegisterLocalProcessMessage pid) =
  liftIO $
  do t1 <- newIORef Nothing
     t2 <- newIORef Nothing
     writeIORef (tsGlobalTimeInvalid server) True
     modifyIORef (tsProcesses server) $
       M.insert pid LocalProcessInfo { lpLocalTime = t1, lpSentGlobalTime = t2 }
processTimeServerMessage server (UnregisterLocalProcessMessage pid) =
  liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing -> return ()
       Just x  ->
         do t0 <- readIORef (tsGlobalTime server) 
            t  <- readIORef (lpLocalTime x)
            when (t0 == t) $
              writeIORef (tsGlobalTimeInvalid server) True
            writeIORef (tsProcesses server) $
              M.delete pid m
processTimeServerMessage server (TerminateTimeServerMessage pid) =
  do pids <-
       liftIO $
       do m <- readIORef (tsProcesses server)
          writeIORef (tsProcesses server) M.empty
          writeIORef (tsGlobalTime server) Nothing
          writeIORef (tsGlobalTimeInvalid server) True
          return (M.keys m)
     forM_ pids $ \pid ->
       DP.send pid TerminateLocalProcessMessage
processTimeServerMessage server (GlobalTimeMessageResp pid t') =
  liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing -> return ()
       Just x  ->
         do t0 <- readIORef (tsGlobalTime server)
            t  <- readIORef (lpLocalTime x)
            when (t /= Just t') $
              do writeIORef (lpLocalTime x) (Just t')
                 when (t0 == t) $
                   writeIORef (tsGlobalTimeInvalid server) True
processTimeServerMessage server (LocalTimeMessage pid t') =
  do t0 <- liftIO $
           do m <- readIORef (tsProcesses server)
              case M.lookup pid m of
                Nothing -> return Nothing
                Just x  ->
                  do t0 <- readIORef (tsGlobalTime server)
                     t  <- readIORef (lpLocalTime x)
                     if t == Just t'
                       then return Nothing
                       else do writeIORef (lpLocalTime x) (Just t')
                               when (t0 == t) $
                                 writeIORef (tsGlobalTimeInvalid server) True
                               t0' <- readIORef (lpSentGlobalTime x)
                               if (t0 == t0') || (isNothing t0)
                                 then return Nothing
                                 else do writeIORef (lpSentGlobalTime x) t0
                                         return t0
     case t0 of
       Nothing -> return ()
       Just t0 ->
         DP.send pid (LocalTimeMessageResp t0)

-- | Validate the time server.
validateTimeServer :: TimeServer -> DP.Process ()
validateTimeServer server =
  do f <- liftIO $ readIORef (tsGlobalTimeInvalid server)
     when f $
       do t0 <- liftIO $ timeServerGlobalTime server
          case t0 of
            Nothing -> return ()
            Just t0 ->
              do liftIO $
                   do writeIORef (tsGlobalTime server) (Just t0)
                      writeIORef (tsGlobalTimeInvalid server) False
                 m <- liftIO $ readIORef (tsProcesses server)
                 forM_ (M.assocs m) $ \(pid, x) ->
                   do t0' <- liftIO $ readIORef (lpSentGlobalTime x)
                      when (t0' /= Just t0) $
                        do liftIO $ writeIORef (lpSentGlobalTime x) (Just t0)
                           DP.send pid (GlobalTimeMessage t0) 

-- | Return the time server global time.
timeServerGlobalTime :: TimeServer -> IO (Maybe Double)
timeServerGlobalTime server =
  do xs <- fmap M.elems $ readIORef (tsProcesses server)
     case xs of
       [] -> return Nothing
       (x : xs') ->
         do t <- readIORef (lpLocalTime x)
            case t of
              Nothing -> return Nothing
              Just t  -> loop xs' t
                where loop [] acc = return (Just acc)
                      loop (x : xs') acc =
                        do t <- readIORef (lpLocalTime x)
                           case t of
                             Nothing -> return Nothing
                             Just t  -> loop xs' (min t acc)

-- | Spawn a new time server with the specified parameters.
spawnTimeServer :: DP.NodeId -> TimeServerParams -> DP.Process DP.ProcessId
spawnTimeServer = undefined
