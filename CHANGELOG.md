
Version 1.4
-----

* Added the leaveSimulation function that allows leaving the simulation prematurely.
  It was made in addition to an ability for new logical processes to enter the already 
  running simulation.
  
* Added the dioProcessDisconnectingEnabled flag to allow logical processes to disconnect
  when the monitoring is enabled, but the time server strategy implies the unregistering of
  disconnected logical processes. But then none process can continue sending messages
  to the disconnected process.

Version 1.3
-----

* Fixed the implementation of the fault-tolerant mode.

Version 1.2
-----

* Fixed a leak of monitor references that are used in the fault tolerant mode only.

Version 1.1.2
-----

* Updated the main page documentation with new recommendations.

Version 1.1.1
-----

* Fixed the documentation.

Version 1.1
-----

* Added the time horizon parameter.

* Increased a frequency of the global virtual time synchronization.

Version 1.0
-----

* Optimized the rollback log.

* Increased the default rollback log threshold.

* Returned the size threshold for the output message queue.

Version 0.8
-----

* No more restriction on the number of output messages, which would lead to throttling.

Version 0.7.4.2
-----

* Provided a more precise estimation of speed of simulation.

Version 0.7.4.1
-----

* Updated the estimaton of speed in the description after recent changes in the sequential module.

Version 0.7.4
-----

* A more graceful termination of the time server in case of self-destruction by time-out.

Version 0.7.3
-----

* Updated so that external software tools could monitor the distributed simulation.

Version 0.7.2
-----

* Improved the stopping of the logical processes in case of shutting the cluster down.

Version 0.7.1
-----

* Added the time server and logical process strategies to shutdown the cluster
  in case of failure by the specified timeout intervals.

Version 0.7
-----

* Fixed the use of the LP abbreviation.

Version 0.6
-----

* Using the mwc-random package for generating random numbers by default.

Version 0.5.1
-----

* Added functions expectEvent and expectProcess.

* Added the Guard module.

Version 0.5
-----

* Added an ability to restore the distributed simulation after temporary connection errors.

* Better finalisation of the distributed simulation.

* Implemented lazy references.

Version 0.3
-----

* Started using Samadi's algorithm to synchronize the global virtual time.

* The logical processes must call registerDIO to connect to the time server.

* Increased the default synchronization time-out and delay.

* Increased the default log size threshold.
