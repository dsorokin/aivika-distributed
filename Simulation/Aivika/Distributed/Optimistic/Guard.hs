
{-# LANGUAGE DeriveGeneric, DeriveDataTypeable, MonoLocalBinds #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Guard
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 8.0.2
--
-- This module defines guards that allow correct finishing the distributed simulation.
--
module Simulation.Aivika.Distributed.Optimistic.Guard
       (-- * Guards With Message Passing
        runMasterGuard,
        runSlaveGuard,
        -- * Guards Without Message Passing
        runMasterGuard_,
        runSlaveGuard_)  where

import GHC.Generics

import Data.Typeable
import Data.Binary
import qualified Data.Map as M

import Control.Monad

import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Serializable

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Distributed.Optimistic.Internal.Expect
import Simulation.Aivika.Distributed.Optimistic.DIO
import Simulation.Aivika.Distributed.Optimistic.Message

-- | Represent the master message.
data MasterMessage a = MasterMessage DP.ProcessId (Maybe a)
                     deriving (Show, Typeable, Generic)

-- | Represent the slave message.
data SlaveMessage a = SlaveMessage DP.ProcessId a
                    deriving (Show, Typeable, Generic)
                   
instance Binary a => Binary (MasterMessage a)
instance Binary a => Binary (SlaveMessage a)

-- | Represents the master guard that waits for all slaves to finish.
data MasterGuard a = MasterGuard { masterGuardSlaveMessages :: Ref DIO (M.Map DP.ProcessId a)
                                   -- ^ the messages of slaves connected to the master
                                 }

-- | Represents the slave guard that waits for the master's acknowledgement.
data SlaveGuard a = SlaveGuard { slaveGuardAcknowledgedMessage :: Ref DIO (Maybe (Maybe a))
                                 -- ^ whether the slave process was acknowledged by the master
                               }

-- | Create a new master guard.
newMasterGuard :: Serializable a => Event DIO (MasterGuard a)
newMasterGuard =
  do r <- liftSimulation $ newRef M.empty
     handleSignal messageReceived $ \(SlaveMessage slaveId a) ->
       modifyRef r $ M.insert slaveId a
     return MasterGuard { masterGuardSlaveMessages = r }

-- | Create a new slave guard.
newSlaveGuard :: Serializable a => Event DIO (SlaveGuard a)
newSlaveGuard =
  do r <- liftSimulation $ newRef Nothing
     handleSignal messageReceived $ \(MasterMessage masterId a) ->
       writeRef r (Just a)
     return SlaveGuard { slaveGuardAcknowledgedMessage = r }

-- | Await until the specified number of slaves are connected to the master.
awaitMasterGuard :: Serializable b
                    => MasterGuard a
                    -- ^ the master guard
                    -> Int
                    -- ^ the number of slaves to wait
                    -> (M.Map DP.ProcessId a -> Event DIO (M.Map DP.ProcessId b))
                    -- ^ process the messages sent by slaves
                    -> Process DIO (M.Map DP.ProcessId b)
awaitMasterGuard guard n transform =
  expectProcess $
  do m <- readRef $ masterGuardSlaveMessages guard
     if M.size m < n
       then return Nothing
       else do m' <- transform m
               inboxId <- liftComp messageInboxId
               forM_ (M.keys m) $ \slaveId ->
                 sendMessage slaveId (MasterMessage inboxId $ M.lookup slaveId m')
               return $ Just m'

-- | Await until the specified master receives notifications from the slave processes.
awaitSlaveGuard :: (Serializable a,
                    Serializable b)
                   => SlaveGuard a
                   -- ^ the slave guard
                   -> DP.ProcessId
                   -- ^ the master process identifier
                   -> Event DIO b
                   -- ^ the message generator
                   -> Process DIO (Maybe a)
                   -- ^ the master's reply
awaitSlaveGuard guard masterId generator =
  do liftEvent $
       do b <- generator
          inboxId <- liftComp messageInboxId
          sendMessage masterId (SlaveMessage inboxId b)
     expectProcess $
       readRef $ slaveGuardAcknowledgedMessage guard

-- | Run the master guard by the specified number of slaves and transform function.
runMasterGuard :: (Serializable a,
                   Serializable b)
                  => Int
                  -- ^ the number of slaves to wait
                  -> (M.Map DP.ProcessId a -> Event DIO (M.Map DP.ProcessId b))
                  -- ^ how to transform the messages from the slave processes in the stop time
                  -> Process DIO (M.Map DP.ProcessId b)
runMasterGuard n transform =
  do source <- liftSimulation newSignalSource
     liftEvent $
       do guard <- newMasterGuard
          enqueueEventWithStopTime $
            runProcess $
            do b <- awaitMasterGuard guard n transform
               liftEvent $
                 triggerSignal source b
     processAwait $ publishSignal source

-- | Run the slave guard by the specified master process identifier and message generator.
runSlaveGuard :: (Serializable a,
                  Serializable b)
                 => DP.ProcessId
                 -- ^ the master process identifier
                 -> Event DIO a
                 -- ^ in the stop time generate a message to pass to the master process
                 -> Process DIO (Maybe b)
                 -- ^ the message returned by the master process
runSlaveGuard masterId generator =
  do source <- liftSimulation newSignalSource
     liftEvent $
       do guard <- newSlaveGuard
          enqueueEventWithStopTime $
            runProcess $
            do b <- awaitSlaveGuard guard masterId generator
               liftEvent $
                 triggerSignal source b
     processAwait $ publishSignal source

-- | Run the master guard by the specified number of slaves when there is no message passing.
runMasterGuard_ :: Int -> Process DIO ()
runMasterGuard_ n =
  do _ <- runMasterGuard n transform :: Process DIO (M.Map DP.ProcessId ())
     return ()
       where transform m = return m

-- | Run the slave guard by the specified master process identifier when there is no message passing.
runSlaveGuard_ :: DP.ProcessId -> Process DIO ()
runSlaveGuard_ masterId =
  do _ <- runSlaveGuard masterId generator :: Process DIO (Maybe ())
     return ()
       where generator = return ()
