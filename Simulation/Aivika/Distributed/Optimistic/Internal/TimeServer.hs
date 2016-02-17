
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
               tsProcesses :: IORef (M.Map DP.ProcessId LocalProcessInfo),
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
  TimeServerParams { tsLoggingPriority = DEBUG,
                     tsExpectTimeout = 1000,
                     tsTimeSyncDelay = 1000
                   }

-- | Create a new time server.
newTimeServer :: TimeServerParams -> IO TimeServer
newTimeServer ps =
  do m  <- newIORef M.empty
     t0 <- newIORef Nothing
     f  <- newIORef False
     return TimeServer { tsParams = ps,
                         tsProcesses = m,
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
  join $ liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing ->
         return $
         logTimeServer server WARNING $
         "Time Server: unknown process identifier " ++ show pid
       Just x  ->
         do t0 <- readIORef (tsGlobalTime server) 
            t  <- readIORef (lpLocalTime x)
            when (t0 .>=. t) $
              writeIORef (tsGlobalTimeInvalid server) True
            writeIORef (tsProcesses server) $
              M.delete pid m
            return $ return ()
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
     logTimeServer server INFO "Time Server: terminating..."
     DP.terminate
processTimeServerMessage server (GlobalTimeMessageResp pid t') =
  join $ liftIO $
  do m <- readIORef (tsProcesses server)
     case M.lookup pid m of
       Nothing ->
         return $
         do logTimeServer server WARNING $
              "Time Server: unknown process identifier " ++ show pid
            processTimeServerMessage server (RegisterLocalProcessMessage pid)
            processTimeServerMessage server (GlobalTimeMessageResp pid t')
       Just x  ->
         do t0 <- readIORef (tsGlobalTime server)
            t  <- readIORef (lpLocalTime x)
            when (t /= Just t') $
              do writeIORef (lpLocalTime x) (Just t')
                 when ((t0 .>=. t) || (t0 .>=. Just t')) $
                   writeIORef (tsGlobalTimeInvalid server) True
            return $ return ()
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
         do t0 <- readIORef (tsGlobalTime server)
            t  <- readIORef (lpLocalTime x)
            if t == Just t'
              then return $ return ()
              else do writeIORef (lpLocalTime x) (Just t')
                      when ((t0 .>=. t) || (t0 .>=. Just t')) $
                        writeIORef (tsGlobalTimeInvalid server) True
                      t0' <- readIORef (lpSentGlobalTime x)
                      if (t0 == t0') || (isNothing t0)
                        then return $ return ()
                        else do writeIORef (lpSentGlobalTime x) t0
                                return $
                                  DP.send pid (LocalTimeMessageResp $ fromJust t0)

-- | Whether the both values are defined and the first is greater than or equaled to the second.
(.>=.) :: Maybe Double -> Maybe Double -> Bool
(.>=.) (Just x) (Just y) = x >= y
(.>=.) _ _ = False

-- | Whether the both values are defined and the first is greater than the second.
(.>.) :: Maybe Double -> Maybe Double -> Bool
(.>.) (Just x) (Just y) = x > y
(.>.) _ _ = False

-- | Validate the time server.
validateTimeServer :: TimeServer -> DP.Process ()
validateTimeServer server =
  do f <- liftIO $ readIORef (tsGlobalTimeInvalid server)
     when f $
       do t0 <- timeServerGlobalTime server
          case t0 of
            Nothing -> return ()
            Just t0 ->
              do t' <- liftIO $ readIORef (tsGlobalTime server)
                 when (t' .>. Just t0) $
                   logTimeServer server NOTICE
                   "Time Server: the global time has decreased"
                 liftIO $
                   do writeIORef (tsGlobalTime server) (Just t0)
                      writeIORef (tsGlobalTimeInvalid server) False
                 m <- liftIO $ readIORef (tsProcesses server)
                 forM_ (M.assocs m) $ \(pid, x) ->
                   do t0' <- liftIO $ readIORef (lpSentGlobalTime x)
                      when (t0' /= Just t0) $
                        do liftIO $ writeIORef (lpSentGlobalTime x) (Just t0)
                           DP.send pid (GlobalTimeMessage $ Just t0) 

-- | Return the time server global time.
timeServerGlobalTime :: TimeServer -> DP.Process (Maybe Double)
timeServerGlobalTime server =
  do t0 <- liftIO $ readIORef (tsGlobalTime server)
     zs <- liftIO $ fmap M.assocs $ readIORef (tsProcesses server)
     case zs of
       [] -> return Nothing
       ((pid, x) : zs') ->
         do t <- liftIO $ readIORef (lpLocalTime x)
            loop zs t
              where loop [] acc = return acc
                    loop ((pid, x) : zs') acc =
                      do t <- liftIO $ readIORef (lpLocalTime x)
                         case t of
                           Nothing ->
                             do DP.send pid (GlobalTimeMessage Nothing)
                                loop zs' Nothing
                           Just _  ->
                             loop zs' (liftM2 min t acc)

-- | Start the time server.
timeServer :: TimeServerParams -> DP.Process ()
timeServer ps =
  do server <- liftIO $ newTimeServer ps
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
          validateTimeServer server

-- | Log the message with the specified priority.
logTimeServer :: TimeServer -> Priority -> String -> DP.Process ()
{-# INLINE logTimeServer #-}
logTimeServer server p message =
  when (tsLoggingPriority (tsParams server) <= p) $
  DP.say $
  embracePriority p ++ " " ++ message

