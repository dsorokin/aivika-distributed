
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
