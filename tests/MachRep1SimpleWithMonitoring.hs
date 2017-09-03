
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

import Control.Monad
import Control.Monad.Trans
import Control.Concurrent
import qualified Control.Distributed.Process as DP
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
        
model :: Simulation DIO Double
model =
  do totalUpTime <- newRef 0.0
     
     let machine =
           do upTime <-
                liftParameter $
                randomExponential meanUpTime
              holdProcess upTime
              liftEvent $ 
                modifyRef totalUpTime (+ upTime)
              repairTime <-
                liftParameter $
                randomExponential meanRepairTime
              holdProcess repairTime
              machine

     runProcessInStartTime machine
     runProcessInStartTime machine

     let upTimeProp =
           do x <- readRef totalUpTime
              y <- liftDynamics time
              return $ x / (2 * y)

     runEventInStartTime $
       enqueueEventIOWithStopTime $
       liftIO $
       putStrLn "Test IO"
     
     runEventInStopTime upTimeProp

runModel :: DP.ProcessId -> DP.Process ()
runModel timeServerId =
  do DP.say "Started simulating..."
     let ps = defaultDIOParams { dioSimulationMonitoringInterval = 5000000 }
         env = defaultDIOEnv { dioSimulationMonitoringAction = Just monitorSimulation }
         m =
           do registerDIO
              a <- runSimulation model specs
              terminateDIO
              return a
     (modelId, modelProcess) <- runDIOWithEnv m ps env timeServerId
     a <- modelProcess
     DP.say $ "The result is " ++ show a

monitorSimulation :: Show a => a -> DP.Process ()
monitorSimulation = DP.say . show

master = \backend nodes ->
  do liftIO . putStrLn $ "Slaves: " ++ show nodes
     let timeServerParams = defaultTimeServerParams { tsSimulationMonitoringInterval = 5000000 }
         env = defaultTimeServerEnv { tsSimulationMonitoringAction = Just monitorSimulation }
     timeServerId  <- DP.spawnLocal $ timeServerWithEnv 1 timeServerParams env
     runModel timeServerId
  
main :: IO ()
main = do
  backend <- initializeBackend "localhost" "8080" rtable
  startMaster backend (master backend)
    where
      rtable :: DP.RemoteTable
      -- rtable = __remoteTable initRemoteTable
      rtable = initRemoteTable
