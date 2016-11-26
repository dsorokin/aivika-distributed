
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

import Data.Typeable
import Data.Binary

import System.Random

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

-- | The time shift when replying the messages.
delta = 0.01

-- | The initial seeds.
seeds = [456, 789]

-- | Create a new random generator by the specified seed.
newRandomRef :: Int -> Simulation DIO (Ref DIO StdGen)
newRandomRef = newRef . mkStdGen

-- | Generate a random number with the specified mean
randomRefExponential :: RandomGen g => Ref DIO g -> Double -> Event DIO Double
randomRefExponential r mu =
  do g <- readRef r
     let (x, g') = random g
     writeRef r g'
     return (- log x * mu)

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
slaveModel :: DP.ProcessId -> Int -> Simulation DIO ()
slaveModel masterId i =
  do inboxId <- liftComp messageInboxId
     g <- newRandomRef $ seeds !! (i - 1)

     let machine =
           do t <- liftDynamics time
              upTime <- randomRefExponential g meanUpTime
              enqueueMessage masterId (t + delta + upTime) (TotalUpTimeChange (inboxId, upTime))
              enqueueMessage masterId (t + delta + upTime) (NRepChange (inboxId, 1))
              enqueueMessage masterId (t + delta + upTime) (RepairPersonCount inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(RepairPersonCountResp (senderId, n)) ->
       do t <- liftDynamics time
          when (n == 1) $
            enqueueMessage masterId (t + delta) (NImmedRepChange (inboxId, 1))
          enqueueMessage masterId (t + delta) (RequestRepairPerson inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(RequestRepairPersonResp senderId) ->
       do t <- liftDynamics time
          repairTime <- randomRefExponential g meanRepairTime
          enqueueMessage masterId (t + delta + repairTime) (ReleaseRepairPerson inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(ReleaseRepairPersonResp senderId) ->
       machine
  
     runEventInStartTime machine

     runEventInStartTime $
       enqueueEventIOWithStopTime $
       liftIO $
       putStrLn "The sub-model finished"

     runEventInStopTime $
       return ()

-- | The main model.       
masterModel :: Int -> Simulation DIO (Double, Double)
masterModel count =
  do totalUpTime <- newRef 0.0
     nRep <- newRef 0
     nImmedRep <- newRef 0

     let maxRepairPersonCount = 1
     repairPerson <- newFCFSResource maxRepairPersonCount

     inboxId <- liftComp messageInboxId

     runEventInStartTime $
       handleSignal messageReceived $ \(TotalUpTimeChange (senderId, x)) ->
       do modifyRef totalUpTime (+ x)
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (TotalUpTimeChangeResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(NRepChange (senderId, x)) ->
       do modifyRef nRep (+ x)
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (NRepChangeResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(NImmedRepChange (senderId, x)) ->
       do modifyRef nImmedRep (+ x)
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (NImmedRepChangeResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(RepairPersonCount senderId) ->
       do n <- resourceCount repairPerson
          t <- liftDynamics time
          enqueueMessage senderId (t + delta) (RepairPersonCountResp (inboxId, n))

     runEventInStartTime $
       handleSignal messageReceived $ \(RequestRepairPerson senderId) ->
       runProcess $
       do requestResource repairPerson
          t <- liftDynamics time
          liftEvent $
            enqueueMessage senderId (t + delta) (RequestRepairPersonResp inboxId)

     runEventInStartTime $
       handleSignal messageReceived $ \(ReleaseRepairPerson senderId) ->
       do t <- liftDynamics time
          releaseResourceWithinEvent repairPerson
          enqueueMessage senderId (t + delta) (ReleaseRepairPersonResp inboxId)
          
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

runSlaveModel :: (DP.ProcessId, DP.ProcessId, Int) -> DP.Process (DP.ProcessId, DP.Process ())
runSlaveModel (timeServerId, masterId, i) =
  runDIO m ps timeServerId
  where
    ps = defaultDIOParams { dioLoggingPriority = WARNING }
    m  = do registerDIO
            runSimulation (slaveModel masterId i) specs
            unregisterDIO

-- remotable ['runSlaveModel, 'timeServer]

runMasterModel :: DP.ProcessId -> Int -> DP.Process (DP.ProcessId, DP.Process (Double, Double))
runMasterModel timeServerId n =
  runDIO m ps timeServerId
  where
    ps = defaultDIOParams { dioLoggingPriority = WARNING }
    m  = do registerDIO
            a <- runSimulation (masterModel n) specs
            terminateDIO
            return a

master = \backend nodes ->
  do liftIO . putStrLn $ "Slaves: " ++ show nodes
     let n = length seeds
         timeServerParams = defaultTimeServerParams { tsLoggingPriority = DEBUG }
     timeServerId <- DP.spawnLocal $ timeServer 3 timeServerParams
     (masterId, masterProcess) <- runMasterModel timeServerId n
     forM_ [1..n] $ \i ->
       do (slaveId, slaveProcess) <- runSlaveModel (timeServerId, masterId, i)
          DP.spawnLocal slaveProcess
     a <- masterProcess
     DP.say $
       "The result is " ++ show a
  
main :: IO ()
main = do
  backend <- initializeBackend "localhost" "8080" rtable
  startMaster backend (master backend)
    where
      rtable :: DP.RemoteTable
      -- rtable = __remoteTable initRemoteTable
      rtable = initRemoteTable
