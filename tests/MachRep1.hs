
{--# LANGUAGE TemplateHaskell #--}
{-# LANGUAGE DeriveGeneric #-}

-- It corresponds to model MachRep1 described in document 
-- Introduction to Discrete-Event Simulation and the SimPy Language
-- [http://heather.cs.ucdavis.edu/~matloff/156/PLN/DESimIntro.pdf]. 
-- SimPy is available on [http://simpy.sourceforge.net/].
--   
-- The model description is as follows.
--
-- Two machines, which sometimes break down.
-- Up time is exponentially distributed with mean 1.0, and repair time is
-- exponentially distributed with mean 0.5. There are two repairpersons,
-- so the two machines can be repaired simultaneously if they are down
-- at the same time.
--
-- Output is long-run proportion of up time. Should get value of about
-- 0.66.

import System.Environment (getArgs)

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
                spcStopTime = 10000.0,
                spcDT = 1.0,
                spcMethod = RungeKutta4,
                spcGeneratorType = SimpleGenerator }

newtype TotalUpTimeChange = TotalUpTimeChange { runTotalUpTimeChange :: Double }
                          deriving (Eq, Ord, Show, Typeable, Generic)

instance Binary TotalUpTimeChange

-- | A sub-model.
slaveModel :: DP.ProcessId -> Simulation DIO ()
slaveModel masterId =
  do let machine =
           do upTime <-
                liftParameter $
                randomExponential meanUpTime
              holdProcess upTime
              ---
              liftEvent $
                sendMessage masterId (TotalUpTimeChange upTime)
              ---
              repairTime <-
                liftParameter $
                randomExponential meanRepairTime
              holdProcess repairTime
              machine

     runProcessInStartTime machine

     runEventInStartTime $
       enqueueEventIOWithStopTime $
       liftIO $
       putStrLn "The sub-model finished"

     runEventInStopTime $
       return ()

-- | The main model.       
masterModel :: Int -> Simulation DIO Double
masterModel n =
  do totalUpTime <- newRef 0.0

     ---
     let totalUpTimeChanged :: Signal DIO TotalUpTimeChange
         totalUpTimeChanged = messageReceived

     runEventInStartTime $
       handleSignal totalUpTimeChanged $ \x ->
       modifyRef totalUpTime (+ runTotalUpTimeChange x)
     ---
     
     let upTimeProp =
           do x <- readRef totalUpTime
              y <- liftDynamics time
              return $ x / (fromIntegral n * y)

     runEventInStopTime upTimeProp

runSlaveModel :: (DP.ProcessId, DP.ProcessId) -> DP.Process (DP.ProcessId, DP.Process ())
runSlaveModel (timeServerId, masterId) =
  runDIO m ps timeServerId
  where
    ps = defaultDIOParams { dioLoggingPriority = NOTICE }
    m  = do runSimulation (slaveModel masterId) specs
            unregisterDIO

runMasterModel :: DP.ProcessId -> Int -> DP.Process (DP.ProcessId, DP.Process Double)
runMasterModel timeServerId n =
  runDIO m ps timeServerId
  where
    ps = defaultDIOParams { dioLoggingPriority = NOTICE }
    m  = do a <- runSimulation (masterModel n) specs
            terminateDIO
            return a

master = \backend nodes ->
  do liftIO . putStrLn $ "Slaves: " ++ show nodes
     let timeServerParams = defaultTimeServerParams { tsLoggingPriority = DEBUG }
     timeServerId <- DP.spawnLocal $ timeServer timeServerParams
     (masterId, masterProcess) <- runMasterModel timeServerId 2
     forM_ [1..2] $ \i ->
       do (slaveId, slaveProcess) <- runSlaveModel (timeServerId, masterId)
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
