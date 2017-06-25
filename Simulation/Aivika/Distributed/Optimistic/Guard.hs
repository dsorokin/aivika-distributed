
{-# LANGUAGE DeriveGeneric, DeriveDataTypeable #-}

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
       (MasterGuard,
        SlaveGuard,
        newMasterGuard,
        newSlaveGuard,
        awaitMasterGuard,
        awaitSlaveGuard)  where

import GHC.Generics

import Data.Typeable
import Data.Binary
import qualified Data.Set as S

import Control.Monad

import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Serializable

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Internal.Types
import Simulation.Aivika.Distributed.Optimistic.DIO
import Simulation.Aivika.Distributed.Optimistic.Message

-- | Represent the master message.
newtype MasterMessage = MasterMessage DP.ProcessId
                      deriving (Show, Typeable, Generic)

-- | Represent the slave message.
newtype SlaveMessage = SlaveMessage DP.ProcessId
                     deriving (Show, Typeable, Generic)
                   
instance Binary MasterMessage
instance Binary SlaveMessage

-- | Represents the master guard that waits for all slaves to finish.
data MasterGuard = MasterGuard { masterGuardSlaveIds :: Ref DIO (S.Set DP.ProcessId)
                                 -- ^ the slaves connected to the master
                               }

-- | Represents the slave guard that waits for the master's acknowledgement.
data SlaveGuard = SlaveGuard { slaveGuardAcknowledged :: Ref DIO Bool
                               -- ^ whether the slave process was acknowledged by the master
                             }

-- | Create a new master guard.
newMasterGuard :: Event DIO MasterGuard
newMasterGuard =
  do r <- liftSimulation $ newRef S.empty
     handleSignal messageReceived $ \(SlaveMessage slaveId) ->
       modifyRef r $ S.insert slaveId
     return MasterGuard { masterGuardSlaveIds = r }

-- | Create a new slave guard.
newSlaveGuard :: Event DIO SlaveGuard
newSlaveGuard =
  do r <- liftSimulation $ newRef False
     handleSignal messageReceived $ \(MasterMessage masterId) ->
       writeRef r True
     return SlaveGuard { slaveGuardAcknowledged = r }

-- | Await until the specified number of slaves are connected to the master.
awaitMasterGuard :: MasterGuard -> Int -> Event DIO ()
awaitMasterGuard guard n =
  Event $ \p ->
  do let t = pointTime p
     invokeEvent p $
       enqueueEvent t $
       expectEvent $
       do s <- readRef $ masterGuardSlaveIds guard
          if S.size s < n
            then return False
            else do inboxId <- liftComp messageInboxId
                    forM_ (S.elems s) $ \slaveId ->
                      sendMessage slaveId (MasterMessage inboxId)
                    return True

-- | Await until the specified master receives notifications from the slave processes.
awaitSlaveGuard :: SlaveGuard -> DP.ProcessId -> Event DIO ()
awaitSlaveGuard guard masterId =
  Event $ \p ->
  do let t = pointTime p
     invokeEvent p $
       do inboxId <- liftComp messageInboxId
          sendMessage masterId (SlaveMessage inboxId)
          enqueueEvent t $
            expectEvent $
            readRef $ slaveGuardAcknowledged guard
