Parallel distributed discrete event simulation module for the Aivika library

The represented [aivika-distributed](http://hackage.haskell.org/package/aivika-distributed) package extends
the [aivika-transformers](http://hackage.haskell.org/package/aivika-transformers) package and
allows running parallel distributed simulations. It uses an optimistic strategy known as 
the Time Warp method. To synchronize the global virtual time, it uses Samadi's algorithm. 

Moreover, this package uses the author's modification that allows recovering the distributed
simulation after temporary connection errors whenever possible. For that, you have to enable explicitly 
the recovering mode and enable monitoring all local processes including the specialized Time Server process 
as it is shown in one of the test examples included in the distributive.

With the recovering mode enabled, you can try to build a distributed simulation using ordinary computers connected
via the ordinary net. For example, such a distributed model could even consist of computers located in different 
continents of the Earth, where the computers could be connected through the Internet. Here the most exciting thing 
is that this is the optimistic distributed simulation with possible rollbacks. It is assumed that optimistic methods 
tend to better support the parallelism inherited in the models. 

You may test the distributed simulation using your own laptop only, although the package is still destined to be 
used with a multi-core computer, or computers connected in the distributed cluster.

There are additional packages that allow you to run the distributed simulation experiments by 
the Monte-Carlo method. They allow you to save the simulation results in SQL databases and then generate a report 
or a set of reports consisting of HTML pages with charts, histograms, links to CSV tables, summary statistics etc.
Please consult the [AivikaSoft](http://www.aivikasoft.com) website for more details.

Regarding the speed of simulation, the rough estimations are as follows. The simulation is slower up to
6-9 times in comparison with the sequential [aivika](http://hackage.haskell.org/package/aivika) simulation library 
using the equivalent sequential models. Note that you can run up to 7 parallel local processes on a single 
8-core processor computer and run the Time Server process too. On a 36-core processor, you can launch up to 35 local 
processes simultaneously.

So, this estimation seems to be quite good. At the same time, the message passing between the local processes can 
dramatically decrease the speed of distributed simulation, especially if they cause rollbacks. Thus, much depends on 
the distributed model itself.
