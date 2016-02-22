
{--# LANGUAGE TemplateHaskell #--}
{-# LANGUAGE DeriveGeneric #-}

-- It corresponds to model MachRep2 described in document 
-- Introduction to Discrete-Event Simulation and the SimPy Language
-- [http://heather.cs.ucdavis.edu/~matloff/156/PLN/DESimIntro.pdf]. 
-- SimPy is available on [http://simpy.sourceforge.net/].
--   
-- The model description is as follows.
--   
-- Two machines, but sometimes break down. Up time is exponentially 
-- distributed with mean 1.0, and repair time is exponentially distributed 
-- with mean 0.5. In this example, there is only one repairperson, so 
-- the two machines cannot be repaired simultaneously if they are down 
-- at the same time.
--
-- In addition to finding the long-run proportion of up time as in
-- model MachRep1, let’s also find the long-run proportion of the time 
-- that a given machine does not have immediate access to the repairperson 
-- when the machine breaks down. Output values should be about 0.6 and 0.67. 

-- import System.Environment (getArgs)

import Data.Typeable
import Data.Binary

import GHC.Generics

import Control.Monad
import Control.Monad.Trans
import Control.Concurrent
import qualified Control.Distributed.Process as DP
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Distributed.Process.Backend.SimpleLocalnet

import Simulation.Aivika.Trans
import Simulation.Aivika.Distributed

meanUpTime = 1.0
meanRepairTime = 0.5

specs = Specs { spcStartTime = 0.0,
                spcStopTime = 1000.0,
                spcDT = 1.0,
                spcMethod = RungeKutta4,
                spcGeneratorType = SimpleGenerator }

data TotalUpTimeChange = TotalUpTimeChange (DP.ProcessId, Double) deriving (Eq, Ord, Show, Typeable, Generic)
data TotalUpTimeChangeResp = TotalUpTimeChangeResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data NRepChange = NRepChange (DP.ProcessId, Int) deriving (Eq, Ord, Show, Typeable, Generic)
data NRepChangeResp = NRepChangeResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data NImmedRepChange = NImmedRepChange (DP.ProcessId, Int) deriving (Eq, Ord, Show, Typeable, Generic)
data NImmedRepChangeResp = NImmedRepChangeResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data RepairPersonCount = RepairPersonCount DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)
data RepairPersonCountResp = RepairPersonCountResp (DP.ProcessId, Int) deriving (Eq, Ord, Show, Typeable, Generic)

data RequestRepairPerson = RequestRepairPerson DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)
data RequestRepairPersonResp = RequestRepairPersonResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

data ReleaseRepairPerson = ReleaseRepairPerson DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)
data ReleaseRepairPersonResp = ReleaseRepairPersonResp DP.ProcessId deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TotalUpTimeChange
instance Binary TotalUpTimeChangeResp

instance Binary NRepChange
instance Binary NRepChangeResp

instance Binary NImmedRepChange
instance Binary NImmedRepChangeResp

instance Binary RepairPersonCount
instance Binary RepairPersonCountResp

instance Binary RequestRepairPerson
instance Binary RequestRepairPersonResp

instance Binary ReleaseRepairPerson
instance Binary ReleaseRepairPersonResp

-- | A sub-model.
slaveModel :: DP.ProcessId -> Simulation DIO ()
slaveModel masterId =
  do inboxId <- liftComp messageInboxId
  
     let machine =
           do upTime <-
                randomExponentialProcess meanUpTime
              liftEvent $
                sendMessage masterId (TotalUpTimeChange (inboxId, upTime))

              liftEvent $
                do sendMessage masterId (NRepChange (inboxId, 1))
                   sendMessage masterId (RepairPersonCount inboxId)
                   
              RepairPersonCountResp (senderId, n) <- processAwait messageReceived
              when (n == 1) $
                liftEvent $
                sendMessage masterId (NImmedRepChange (inboxId, 1))

              liftEvent $
                sendMessage masterId (RequestRepairPerson inboxId)
              RequestRepairPersonResp senderId <- processAwait messageReceived
              repairTime <-
                randomExponentialProcess meanRepairTime
              liftEvent $
                sendMessage masterId (ReleaseRepairPerson inboxId)

              machine

     runProcessInStartTime machine

     syncEventInStopTime $
       liftIO $ putStrLn "The sub-model finished"

-- | The main model.       
masterModel :: Int -> Simulation DIO (Double, Double)
masterModel count =
  do totalUpTime <- newRef 0.0
     nRep <- newRef 0
     nImmedRep <- newRef 0

     repairPerson <- newFCFSResource 1

     inboxId <- liftComp messageInboxId

     let totalUpTimeChanged = messageReceived :: Signal DIO TotalUpTimeChange
         nRepChanged = messageReceived :: Signal DIO NRepChange
         nImmedRepChanged = messageReceived :: Signal DIO NImmedRepChange
         
         repairPersonCounting = messageReceived :: Signal DIO RepairPersonCount
         repairPersonRequested = messageReceived :: Signal DIO RequestRepairPerson
         repairPersonReleased = messageReceived :: Signal DIO ReleaseRepairPerson

     runEventInStartTime $
       handleSignal totalUpTimeChanged $ \(TotalUpTimeChange (senderId, x)) ->
       do modifyRef totalUpTime (+ x)
          sendMessage senderId (TotalUpTimeChangeResp inboxId)

     runEventInStartTime $
       handleSignal nRepChanged $ \(NRepChange (senderId, x)) ->
       do modifyRef nRep (+ x)
          sendMessage senderId (NRepChangeResp inboxId)

     runEventInStartTime $
       handleSignal nImmedRepChanged $ \(NImmedRepChange (senderId, x)) ->
       do modifyRef nImmedRep (+ x)
          sendMessage senderId (NImmedRepChangeResp inboxId)

     runEventInStartTime $
       handleSignal repairPersonCounting $ \(RepairPersonCount senderId) ->
       do n <- resourceCount repairPerson
          sendMessage senderId (RepairPersonCountResp (inboxId, n))

     runEventInStartTime $
       handleSignal repairPersonRequested $ \(RequestRepairPerson senderId) ->
       runProcess $
       do requestResource repairPerson
          liftEvent $
            sendMessage senderId (RequestRepairPersonResp inboxId)

     runEventInStartTime $
       handleSignal repairPersonReleased $ \(ReleaseRepairPerson senderId) ->
       do releaseResourceWithinEvent repairPerson
          sendMessage senderId (ReleaseRepairPersonResp inboxId)
          
     let upTimeProp =
           do x <- readRef totalUpTime
              y <- liftDynamics time
              return $ x / (fromIntegral count * y)

         immedProp =
           do n <- readRef nRep
              nImmed <- readRef nImmedRep
              return $
                fromIntegral nImmed /
                fromIntegral n

     runEventInStopTime $
       do x <- upTimeProp
          y <- immedProp
          return (x, y)

runSlaveModel :: (DP.ProcessId, DP.ProcessId) -> DP.Process (DP.ProcessId, DP.Process ())
runSlaveModel (timeServerId, masterId) =
  runDIO m ps timeServerId
  where
    ps = defaultDIOParams { dioLoggingPriority = NOTICE }
    m  = do runSimulation (slaveModel masterId) specs
            unregisterDIO

-- remotable ['runSlaveModel, 'timeServer]

runMasterModel :: DP.ProcessId -> Int -> DP.Process (DP.ProcessId, DP.Process (Double, Double))
runMasterModel timeServerId n =
  runDIO m ps timeServerId
  where
    ps = defaultDIOParams { dioLoggingPriority = NOTICE }
    m  = do a <- runSimulation (masterModel n) specs
            terminateDIO
            return a

master = \backend nodes ->
  do liftIO . putStrLn $ "Slaves: " ++ show nodes
     timeServerId <- DP.spawnLocal $ timeServer defaultTimeServerParams
     -- timeServerId <- DP.spawn node1 ($(mkClosure 'timeServer) defaultTimeServerParams)
     (masterId, masterProcess) <- runMasterModel timeServerId 2
     -- (masterId, masterProcess) <- runMasterModel timeServerId (length nodes)
     -- forM_ nodes $ \node ->
     --   DP.spawn node ($(mkClosure 'runSlaveModel) (timeServerId, masterId))
     forM_ [1..2] $ \i ->
       do (slaveId, slaveProcess) <- runSlaveModel (timeServerId, masterId)
          DP.spawnLocal slaveProcess
     a <- masterProcess
     DP.say $
       "The result is " ++ show a
  
main :: IO ()
main = do
  backend <- initializeBackend "localhost" "8080" initRemoteTable
  startMaster backend (master backend)
