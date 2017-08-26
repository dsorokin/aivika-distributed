
{-# LANGUAGE DeriveGeneric, DeriveDataTypeable #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.DIO
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines a distributed computation based on 'IO'.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.DIO
       (DIO(..),
        DIOParams(..),
        DIOStrategy(..),
        invokeDIO,
        runDIO,
        defaultDIOParams,
        terminateDIO,
        registerDIO,
        unregisterDIO,
        monitorProcessDIO,
        dioParams,
        messageChannel,
        messageInboxId,
        timeServerId,
        sendMessageDIO,
        sendMessagesDIO,
        sendAcknowledgmentMessageDIO,
        sendAcknowledgmentMessagesDIO,
        sendLocalTimeDIO,
        sendRequestGlobalTimeDIO,
        logDIO,
        liftDistributedUnsafe) where

import Data.Typeable
import Data.Binary
import Data.IORef
import Data.Time.Clock

import GHC.Generics

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Exception (throw)
import Control.Monad.Catch as C
import qualified Control.Distributed.Process as DP
import Control.Concurrent
import Control.Concurrent.STM

import System.Timeout

import Simulation.Aivika.Trans.Exception
import Simulation.Aivika.Trans.Internal.Types

import Simulation.Aivika.Distributed.Optimistic.Internal.Channel
import Simulation.Aivika.Distributed.Optimistic.Internal.Message
import Simulation.Aivika.Distributed.Optimistic.Internal.TimeServer
import Simulation.Aivika.Distributed.Optimistic.Internal.Priority
import Simulation.Aivika.Distributed.Optimistic.Internal.KeepAliveManager

-- | The parameters for the 'DIO' computation.
data DIOParams =
  DIOParams { dioLoggingPriority :: Priority,
              -- ^ The logging priority
              dioUndoableLogSizeThreshold :: Int,
              -- ^ The undoable log size threshold used for detecting an overflow
              dioOutputMessageQueueSizeThreshold :: Int,
              -- ^ The output message queue size threshold used for detecting an overflow
              dioTransientMessageQueueSizeThreshold :: Int,
              -- ^ The transient message queue size threshold used for detecting an overflow
              dioSyncTimeout :: Int,
              -- ^ The timeout in microseconds used for synchronising the operations
              dioAllowPrematureIO :: Bool,
              -- ^ Whether to allow performing the premature IO action; otherwise, raise an error
              dioAllowSkippingOutdatedMessage :: Bool,
              -- ^ Whether to allow skipping an outdated message with the receive time less than the global time,
              -- which is possible after reconnection
              dioProcessMonitoringEnabled :: Bool,
              -- ^ Whether the process monitoring is enabled
              dioProcessMonitoringDelay :: Int,
              -- ^ The delay in microseconds which must be applied for monitoring every remote process.
              dioProcessReconnectingEnabled :: Bool,
              -- ^ Whether the automatic reconnecting to processes is enabled when enabled monitoring
              dioProcessReconnectingDelay :: Int,
              -- ^ The timeout in microseconds before reconnecting to the remote process
              dioKeepAliveInterval :: Int,
              -- ^ The interval in microseconds for sending keep-alive messages
              dioTimeServerAcknowledgmentTimeout :: Int,
              -- ^ The timeout in microseconds for receiving an acknowledgment message from the time server
              dioStrategy :: DIOStrategy
              -- ^ The logical process strategy
            } deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary DIOParams

-- | The logical process strategy.
data DIOStrategy = WaitIndefinitelyForTimeServer
                   -- ^ Wait the time server forever
                 | TerminateDueToTimeServerTimeout Int
                   -- ^ Terminate due to the exceeded time server timeout in microseconds, but not less than 'dioSyncTimeout'
                 deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary DIOStrategy

-- | The distributed computation based on 'IO'.
newtype DIO a = DIO { unDIO :: DIOContext -> DP.Process a
                      -- ^ Unwrap the computation.
                    }

-- | The context of the 'DIO' computation.
data DIOContext =
  DIOContext { dioChannel :: Channel LogicalProcessMessage,
               -- ^ The channel of messages.
               dioInboxId :: DP.ProcessId,
               -- ^ The inbox process identifier.
               dioTimeServerId :: DP.ProcessId,
               -- ^ The time server process
               dioParams0 :: DIOParams,
               -- ^ The parameters of the computation.
               dioRegisteredInTimeServer :: TVar Bool,
               -- ^ Whether the compution is registered in the time server.
               dioUnregisteredFromTimeServer :: TVar Bool,
               -- ^ Whether the compution is unregistered from the time server.
               dioTimeServerTerminating :: TVar Bool
               -- ^ Whether the compution asked to terminate the time server.
             }

instance Monad DIO where

  {-# INLINE return #-}
  return = DIO . const . return

  {-# INLINE (>>=) #-}
  (DIO m) >>= k = DIO $ \ps ->
    m ps >>= \a ->
    let m' = unDIO (k a) in m' ps

instance Applicative DIO where

  {-# INLINE pure #-}
  pure = return

  {-# INLINE (<*>) #-}
  (<*>) = ap

instance Functor DIO where

  {-# INLINE fmap #-}
  fmap f (DIO m) = DIO $ fmap f . m 

instance MonadException DIO where

  catchComp (DIO m) h = DIO $ \ps ->
    C.catch (m ps) (\e -> unDIO (h e) ps)

  finallyComp (DIO m1) (DIO m2) = DIO $ \ps ->
    C.finally (m1 ps) (m2 ps)
  
  throwComp e = DIO $ \ps ->
    throw e

-- | Invoke the 'DIO' computation.
invokeDIO :: DIOContext -> DIO a -> DP.Process a
{-# INLINE invokeDIO #-}
invokeDIO ps (DIO m) = m ps

-- | Lift the distributed 'Process' computation.
liftDistributedUnsafe :: DP.Process a -> DIO a
liftDistributedUnsafe = DIO . const

-- | The default parameters for the 'DIO' computation
defaultDIOParams :: DIOParams
defaultDIOParams =
  DIOParams { dioLoggingPriority = WARNING,
              dioUndoableLogSizeThreshold = 1000000,
              dioOutputMessageQueueSizeThreshold = 10000,
              dioTransientMessageQueueSizeThreshold = 10000,
              dioSyncTimeout = 60000000,
              dioAllowPrematureIO = False,
              dioAllowSkippingOutdatedMessage = True,
              dioProcessMonitoringEnabled = False,
              dioProcessMonitoringDelay = 5000000,
              dioProcessReconnectingEnabled = False,
              dioProcessReconnectingDelay = 5000000,
              dioKeepAliveInterval = 5000000,
              dioTimeServerAcknowledgmentTimeout = 5000000,
              dioStrategy = TerminateDueToTimeServerTimeout 300000000
            }

-- | Return the computation context.
dioContext :: DIO DIOContext
dioContext = DIO return

-- | Return the parameters of the current computation.
dioParams :: DIO DIOParams
dioParams = DIO $ return . dioParams0

-- | Return the chanel of messages.
messageChannel :: DIO (Channel LogicalProcessMessage)
messageChannel = DIO $ return . dioChannel

-- | Return the process identifier of the inbox that receives messages.
messageInboxId :: DIO DP.ProcessId
messageInboxId = DIO $ return . dioInboxId

-- | Return the time server process identifier.
timeServerId :: DIO DP.ProcessId
timeServerId = DIO $ return . dioTimeServerId

-- | Terminate the simulation including the processes in
-- all nodes connected to the time server.
terminateDIO :: DIO ()
terminateDIO =
  DIO $ \ctx ->
  do let ps = dioParams0 ctx
     logProcess ps INFO "Terminating the simulation..."
     sender   <- invokeDIO ctx messageInboxId
     receiver <- invokeDIO ctx timeServerId
     let inbox = sender
     if dioProcessMonitoringEnabled ps
       then DP.send inbox (SendTerminateTimeServerMessage receiver sender)
       else DP.send receiver (TerminateTimeServerMessage sender)
     liftIO $
       timeout (dioTimeServerAcknowledgmentTimeout ps) $
       atomically $
       do f <- readTVar (dioTimeServerTerminating ctx)
          unless f retry
     DP.send inbox TerminateInboxProcessMessage
     return ()

-- | Register the simulation process in the time server, which
-- requires some initial quorum to start synchronizing the global time.
registerDIO :: DIO ()
registerDIO =
  DIO $ \ctx ->
  do let ps = dioParams0 ctx
     logProcess ps INFO "Registering the simulation process..."
     sender   <- invokeDIO ctx messageInboxId
     receiver <- invokeDIO ctx timeServerId
     let inbox = sender
     if dioProcessMonitoringEnabled ps
       then DP.send inbox (SendRegisterLogicalProcessMessage receiver sender)
       else DP.send receiver (RegisterLogicalProcessMessage sender)
     liftIO $
       timeout (dioTimeServerAcknowledgmentTimeout ps) $
       atomically $
       do f <- readTVar (dioRegisteredInTimeServer ctx)
          unless f retry
     return ()

-- | Unregister the simulation process from the time server
-- without affecting the processes in other nodes connected to
-- the corresponding time server.
unregisterDIO :: DIO ()
unregisterDIO =
  DIO $ \ctx ->
  do let ps = dioParams0 ctx
     logProcess ps INFO "Unregistering the simulation process..."
     sender   <- invokeDIO ctx messageInboxId
     receiver <- invokeDIO ctx timeServerId
     let inbox = sender
     if dioProcessMonitoringEnabled ps
       then DP.send inbox (SendUnregisterLogicalProcessMessage receiver sender)
       else DP.send receiver (UnregisterLogicalProcessMessage sender)
     liftIO $
       timeout (dioTimeServerAcknowledgmentTimeout ps) $
       atomically $
       do f <- readTVar (dioUnregisteredFromTimeServer ctx)
          unless f retry
     DP.send inbox TerminateInboxProcessMessage
     return ()

-- | The internal logical process message.
data InternalLogicalProcessMessage = InternalLogicalProcessMessage LogicalProcessMessage
                                     -- ^ the logical process message
                                   | InternalProcessMonitorNotification DP.ProcessMonitorNotification
                                     -- ^ the process monitor notification
                                   | InternalInboxProcessMessage InboxProcessMessage
                                     -- ^ the inbox process message
                                   | InternalKeepAliveMessage KeepAliveMessage
                                     -- ^ the keep alive message

-- | Handle the specified exception.
handleException :: DIOParams -> SomeException -> DP.Process ()
handleException ps e =
  do ---
     logProcess ps ERROR $ "Exception occured: " ++ show e
     ---
     C.throwM e

-- | Run the computation using the specified parameters along with time server process
-- identifier and return the inbox process identifier and a new simulation process.
runDIO :: DIO a -> DIOParams -> DP.ProcessId -> DP.Process (DP.ProcessId, DP.Process a)
runDIO m ps serverId =
  do ch <- liftIO newChannel
     let keepAliveParams =
           KeepAliveParams { keepAliveLoggingPriority = dioLoggingPriority ps,
                             keepAliveInterval = dioKeepAliveInterval ps }
     keepAliveManager <- liftIO $ newKeepAliveManager keepAliveParams
     terminated <- liftIO $ newIORef False
     registeredInTimeServer <- liftIO $ newTVarIO False
     unregisteredFromTimeServer <- liftIO $ newTVarIO False
     timeServerTerminating <- liftIO $ newTVarIO False
     timeServerTimestamp <- liftIO $ getCurrentTime >>= newIORef
     let loop =
           forever $
           do let f1 :: LogicalProcessMessage -> DP.Process InternalLogicalProcessMessage
                  f1 x = return (InternalLogicalProcessMessage x)
                  f2 :: DP.ProcessMonitorNotification -> DP.Process InternalLogicalProcessMessage
                  f2 x = return (InternalProcessMonitorNotification x)
                  f3 :: InboxProcessMessage -> DP.Process InternalLogicalProcessMessage
                  f3 x = return (InternalInboxProcessMessage x)
                  f4 :: KeepAliveMessage -> DP.Process InternalLogicalProcessMessage
                  f4 x = return (InternalKeepAliveMessage x)
              x <- fmap Just $ DP.receiveWait [DP.match f1, DP.match f2, DP.match f3, DP.match f4]
              case x of
                Nothing -> return ()
                Just (InternalLogicalProcessMessage m) ->
                  liftIO $
                  do stampTimeServerMessage m timeServerTimestamp
                     writeChannel ch m
                Just (InternalProcessMonitorNotification m@(DP.ProcessMonitorNotification _ _ _)) ->
                  handleProcessMonitorNotification m ps ch serverId
                Just (InternalInboxProcessMessage m) ->
                  case m of
                    SendQueueMessage pid m ->
                      DP.send pid (QueueMessage m)
                    SendQueueMessageBulk pid ms ->
                      forM_ ms $ \m ->
                      DP.send pid (QueueMessage m)
                    SendAcknowledgmentQueueMessage pid m ->
                      DP.send pid (AcknowledgmentQueueMessage m)
                    SendAcknowledgmentQueueMessageBulk pid ms ->
                      forM_ ms $ \m ->
                      DP.send pid (AcknowledgmentQueueMessage m)
                    SendLocalTimeMessage receiver sender t ->
                      DP.send receiver (LocalTimeMessage sender t)
                    SendRequestGlobalTimeMessage receiver sender ->
                      DP.send receiver (RequestGlobalTimeMessage sender)
                    SendRegisterLogicalProcessMessage receiver sender ->
                      DP.send receiver (RegisterLogicalProcessMessage sender)
                    SendUnregisterLogicalProcessMessage receiver sender ->
                      DP.send receiver (UnregisterLogicalProcessMessage sender)
                    SendTerminateTimeServerMessage receiver sender ->
                      DP.send receiver (TerminateTimeServerMessage sender)
                    MonitorProcessMessage pid ->
                      do ---
                         logProcess ps INFO $ "Monitoring process " ++ show pid
                         ---
                         DP.monitor pid
                         liftIO $
                           addKeepAliveReceiver keepAliveManager pid
                         return ()
                    ReMonitorProcessMessage pids ->
                      handleReMonitorProcessMessage pids ps ch
                    TrySendKeepAliveMessage ->
                      trySendKeepAlive keepAliveManager
                    RegisterLogicalProcessAcknowledgmentMessage pid ->
                      do ---
                         logProcess ps INFO "Registered the logical process in the time server"
                         ---
                         liftIO $
                           atomically $
                           writeTVar registeredInTimeServer True
                    UnregisterLogicalProcessAcknowledgmentMessage pid ->
                      do ---
                         logProcess ps INFO "Unregistered the logical process from the time server"
                         ---
                         liftIO $
                           atomically $
                           writeTVar unregisteredFromTimeServer True
                    TerminateTimeServerAcknowledgmentMessage pid ->
                      do ---
                         logProcess ps INFO "Started terminating the time server"
                         ---
                         liftIO $
                           atomically $
                           writeTVar timeServerTerminating True
                    TerminateInboxProcessMessage ->
                      do ---
                         logProcess ps INFO "Terminating the inbox and keep-alive processes..."
                         ---
                         liftIO $
                           atomicWriteIORef terminated True
                         DP.terminate
                Just (InternalKeepAliveMessage m) ->
                  do ---
                     logProcess ps DEBUG $ "Received " ++ show m
                     ---
                     return ()
     inboxId <-
       DP.spawnLocal $
       C.catch loop (handleException ps)
     DP.spawnLocal $
       let loop =
             do f <- liftIO $ readIORef terminated
                unless f $
                  do liftIO $
                       threadDelay (dioKeepAliveInterval ps)
                     DP.send inboxId TrySendKeepAliveMessage
                     loop
       in C.catch loop (handleException ps)
     DP.spawnLocal $
       let loop =
             do f <- liftIO $ readIORef terminated
                unless (f || dioStrategy ps == WaitIndefinitelyForTimeServer) $
                  do liftIO $
                       threadDelay (dioSyncTimeout ps)
                     validateTimeServer ps inboxId timeServerTimestamp
                     loop
       in C.catch loop (handleException ps)
     let simulation =
           unDIO m DIOContext { dioChannel = ch,
                                dioInboxId = inboxId,
                                dioTimeServerId = serverId,
                                dioParams0 = ps,
                                dioRegisteredInTimeServer = registeredInTimeServer,
                                dioUnregisteredFromTimeServer = unregisteredFromTimeServer,
                                dioTimeServerTerminating = timeServerTerminating }
     return (inboxId, simulation)

-- | Handle the process monitor notification.
handleProcessMonitorNotification :: DP.ProcessMonitorNotification -> DIOParams -> Channel LogicalProcessMessage -> DP.ProcessId -> DP.Process ()
handleProcessMonitorNotification m@(DP.ProcessMonitorNotification _ pid0 reason) ps ch serverId =
  do let recv m@(DP.ProcessMonitorNotification _ _ _) = 
           do ---
              logProcess ps WARNING $ "Received a process monitor notification " ++ show m
              ---
              liftIO $
                writeChannel ch (ProcessMonitorNotificationMessage m)
              return m
     recv m
     when (pid0 == serverId) $
       case reason of
         DP.DiedNormal      -> processTimeServerTerminated ps serverId 
         DP.DiedException _ -> processTimeServerTerminated ps serverId
         DP.DiedNodeDown    -> processTimeServerTerminated ps serverId
         _                  -> return ()
     when (dioProcessReconnectingEnabled ps && (reason == DP.DiedDisconnect)) $
       do liftIO $
            threadDelay (dioProcessReconnectingDelay ps)
          let pred m@(DP.ProcessMonitorNotification _ _ reason) = reason == DP.DiedDisconnect
              loop :: [DP.ProcessId] -> DP.Process [DP.ProcessId]
              loop acc =
                do y <- DP.receiveTimeout 0 [DP.matchIf pred recv]
                   case y of
                     Nothing -> return $ reverse acc
                     Just m@(DP.ProcessMonitorNotification _ pid _) -> loop (pid : acc)
          pids <- loop [pid0]
          ---
          logProcess ps NOTICE "Begin reconnecting..."
          ---
          forM_ pids $ \pid ->
            do ---
               logProcess ps NOTICE $ "Direct reconnecting to " ++ show pid
               ---
               DP.reconnect pid
          inboxId <- DP.getSelfPid
          DP.spawnLocal $
            let action =
                  do liftIO $
                       threadDelay (dioProcessMonitoringDelay ps)
                     ---
                     logProcess ps NOTICE $ "Proceed to the re-monitoring"
                     ---
                     DP.send inboxId (ReMonitorProcessMessage pids)
            in C.catch action (handleException ps)
          return ()

-- | Re-monitor the specified remote processes.
handleReMonitorProcessMessage :: [DP.ProcessId] -> DIOParams -> Channel LogicalProcessMessage -> DP.Process ()
handleReMonitorProcessMessage pids ps ch =
  forM_ pids $ \pid ->
  do ---
     logProcess ps NOTICE $ "Re-monitoring " ++ show pid
     ---
     DP.monitor pid
     ---
     logProcess ps NOTICE $ "Writing to the channel about reconnecting to " ++ show pid
     ---
     liftIO $
       writeChannel ch (ReconnectProcessMessage pid)

-- | Monitor the specified process.
monitorProcessDIO :: DP.ProcessId -> DIO ()
monitorProcessDIO pid =
  do ps <- dioParams
     if dioProcessMonitoringEnabled ps
       then do inbox <- messageInboxId
               liftDistributedUnsafe $
                 DP.send inbox $
                 MonitorProcessMessage pid
       else liftDistributedUnsafe $
            logProcess ps WARNING "Ignored the process monitoring as it was disabled in the DIO computation parameters"

-- | Stamp the time server message in a stream of messages destined for the logical process.
stampTimeServerMessage :: LogicalProcessMessage -> IORef UTCTime -> IO ()
stampTimeServerMessage ComputeLocalTimeMessage r = getCurrentTime >>= writeIORef r
stampTimeServerMessage (GlobalTimeMessage _)   r = getCurrentTime >>= writeIORef r
stampTimeServerMessage _                       r = return ()

-- | Validate the time server by the specified inbox and recent timestamp.
validateTimeServer :: DIOParams -> DP.ProcessId -> IORef UTCTime -> DP.Process ()
validateTimeServer ps inboxId r =
  do ---
     logProcess ps NOTICE "Validating the time server"
     ---
     case dioStrategy ps of
       WaitIndefinitelyForTimeServer ->
         return ()
       TerminateDueToTimeServerTimeout timeout ->
         do utc0 <- liftIO $ readIORef r
            utc  <- liftIO getCurrentTime
            let dt = fromRational $ toRational (diffUTCTime utc utc0)
            when (secondsToMicroseconds dt > timeout) $
              do ---
                 logProcess ps WARNING "Terminating due to the exceeded time server timeout"
                 ---
                 DP.send inboxId TerminateInboxProcessMessage 

-- | Process the situation when the time server has suddenly been terminated.
processTimeServerTerminated :: DIOParams -> DP.ProcessId -> DP.Process ()
processTimeServerTerminated ps inboxId =
  do ---
     logProcess ps NOTICE "Terminating due to sudden termination of the time server"
     ---
     DP.send inboxId TerminateInboxProcessMessage 

-- | Convert seconds to microseconds.
secondsToMicroseconds :: Double -> Int
secondsToMicroseconds x = fromInteger $ toInteger $ round (1000000 * x)

-- | Send the message.
sendMessageDIO :: DP.ProcessId -> Message -> DIO ()
{-# INLINABLE sendMessageDIO #-}
sendMessageDIO pid m =
  do ps <- dioParams
     if dioProcessMonitoringEnabled ps
       then do inbox <- messageInboxId
               liftDistributedUnsafe $
                 DP.send inbox (SendQueueMessage pid m)
       else liftDistributedUnsafe $
            DP.send pid (QueueMessage m)

-- | Send the bulk of messages.
sendMessagesDIO :: DP.ProcessId -> [Message] -> DIO ()
{-# INLINABLE sendMessagesDIO #-}
sendMessagesDIO pid ms =
  do ps <- dioParams
     if dioProcessMonitoringEnabled ps
       then do inbox <- messageInboxId
               liftDistributedUnsafe $
                 DP.send inbox (SendQueueMessageBulk pid ms)
       else do forM_ ms $ \m ->
                 liftDistributedUnsafe $
                 DP.send pid (QueueMessage m)

-- | Send the acknowledgment message.
sendAcknowledgmentMessageDIO :: DP.ProcessId -> AcknowledgmentMessage -> DIO ()
{-# INLINABLE sendAcknowledgmentMessageDIO #-}
sendAcknowledgmentMessageDIO pid m =
  do ps <- dioParams
     if dioProcessMonitoringEnabled ps
       then do inbox <- messageInboxId
               liftDistributedUnsafe $
                 DP.send inbox (SendAcknowledgmentQueueMessage pid m)
       else liftDistributedUnsafe $
            DP.send pid (AcknowledgmentQueueMessage m)

-- | Send the bulk of acknowledgment messages.
sendAcknowledgmentMessagesDIO :: DP.ProcessId -> [AcknowledgmentMessage] -> DIO ()
{-# INLINABLE sendAcknowledgmentMessagesDIO #-}
sendAcknowledgmentMessagesDIO pid ms =
  do ps <- dioParams
     if dioProcessMonitoringEnabled ps
       then do inbox <- messageInboxId
               liftDistributedUnsafe $
                 DP.send inbox (SendAcknowledgmentQueueMessageBulk pid ms)
       else do forM_ ms $ \m ->
                 liftDistributedUnsafe $
                 DP.send pid (AcknowledgmentQueueMessage m)

-- | Send the local time to the time server.
sendLocalTimeDIO :: DP.ProcessId -> DP.ProcessId -> Double -> DIO ()
{-# INLINABLE sendLocalTimeDIO #-}
sendLocalTimeDIO receiver sender t =
  do ps <- dioParams
     if dioProcessMonitoringEnabled ps
       then do inbox <- messageInboxId
               liftDistributedUnsafe $
                 DP.send inbox (SendLocalTimeMessage receiver sender t)
       else liftDistributedUnsafe $
            DP.send receiver (LocalTimeMessage sender t)

-- | Send the request for the global virtual time to the time server.
sendRequestGlobalTimeDIO :: DP.ProcessId -> DP.ProcessId -> DIO ()
{-# INLINABLE sendRequestGlobalTimeDIO #-}
sendRequestGlobalTimeDIO receiver sender =
  do ps <- dioParams
     if dioProcessMonitoringEnabled ps
       then do inbox <- messageInboxId
               liftDistributedUnsafe $
                 DP.send inbox (SendRequestGlobalTimeMessage receiver sender)
       else liftDistributedUnsafe $
            DP.send receiver (RequestGlobalTimeMessage sender)

-- | Log the message with the specified priority.
logDIO :: Priority -> String -> DIO ()
{-# INLINE logDIO #-}
logDIO p message =
  do ps <- dioParams
     when (dioLoggingPriority ps <= p) $
       liftDistributedUnsafe $
       DP.say $
       embracePriority p ++ " " ++ message

-- | Log the message with the specified priority.
logProcess :: DIOParams -> Priority -> String -> DP.Process ()
{-# INLINE logProcess #-}
logProcess ps p message =
  when (dioLoggingPriority ps <= p) $
  DP.say $
  embracePriority p ++ " " ++ message
