
{-# LANGUAGE DeriveGeneric, TemplateHaskell #-}

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
        spawnTimeServer,
        spawnLocalTimeServer) where

import qualified Data.Map as M
import Data.Maybe
import Data.IORef
import Data.Typeable
import Data.Binary

import GHC.Generics

import Control.Monad
import Control.Monad.Trans
import Control.Concurrent
import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Closure (remotable, mkClosure)

import Simulation.Aivika.Distributed.Optimistic.Internal.Message

-- | The time server parameters.
data TimeServerParams =
  TimeServerParams { tsExpectTimeout :: Int,
                     -- ^ the timeout in milliseconds within which a new message is expected
                     tsTimeSyncDelay :: Int
                     -- ^ the further delay in milliseconds before the time synchronization
                   } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TimeServerParams

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
defaultTimeServerParams =
  TimeServerParams { tsExpectTimeout = 100,
                     tsTimeSyncDelay = 100
                   }

-- | Create a new time server.
newTimeServer :: IO TimeServer
newTimeServer =
  do m  <- newIORef M.empty
     t0 <- newIORef Nothing
     f  <- newIORef False
     return TimeServer { tsProcesses = m,
                         tsGlobalTime = t0,
                         tsGlobalTimeInvalid = f
                       }

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
          return $ filter (/= pid) (M.keys m)
     forM_ pids $ \pid ->
       DP.send pid TerminateLocalProcessMessage
     DP.terminate
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

-- | The time server loop.
timeServerLoop :: TimeServerParams -> DP.Process ()
timeServerLoop ps =
  do server <- liftIO newTimeServer
     forever $
       do m <- DP.expectTimeout (tsExpectTimeout ps) :: DP.Process (Maybe TimeServerMessage)
          case m of
            Nothing -> return ()
            Just m  ->
              do ---
                 DP.say $ "Time Server: " ++ show m
                 ---
                 processTimeServerMessage server m
          liftIO $
            threadDelay (1000 * tsTimeSyncDelay ps)
          validateTimeServer server

remotable ['timeServerLoop]

-- | Spawn a new time server with the specified parameters.
spawnTimeServer :: DP.NodeId -> TimeServerParams -> DP.Process DP.ProcessId
spawnTimeServer node ps =
  DP.spawn node ($(mkClosure 'timeServerLoop) ps)

-- | Spawn a new local time server with the specified parameters.
spawnLocalTimeServer :: TimeServerParams -> DP.Process DP.ProcessId
spawnLocalTimeServer ps =
  DP.spawnLocal (timeServerLoop ps)
