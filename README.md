Parallel distributed discrete event simulation module for the Aivika library

The represented [aivika-distributed](http://hackage.haskell.org/package/aivika-distributed) package extends
the [aivika-transformers](http://hackage.haskell.org/package/aivika-transformers) package and
allows running parallel distributed simulations. It uses an optimistic strategy known as 
the Time Warp method. To synchronize the global virtual time, it uses Samadi's algorithm. 

Moreover, this package uses the author's modification that allows recovering the distributed
simulation after temporary connection errors whenever possible. For that, you have to enable explicitly 
the recovering mode and enable the monitoring of all logical processes including the specialized Time Server process 
as it is shown in one of the test examples included in the distribution.

With the recovering mode enabled, you can try to build a distributed simulation using ordinary computers connected
via the ordinary net. For example, such a distributed model could even consist of computers located in different 
continents of the Earth, where the computers could be connected through the Internet. Here the most exciting thing 
is that this is the optimistic distributed simulation with possible rollbacks. It is assumed that optimistic methods 
tend to better support the parallelism inherited in the models. 

You can test the distributed simulation using your own laptop, although the package is still destined to be 
used with a multi-core computer, or computers connected in the distributed cluster.

There are additional packages that allow you to run the distributed simulation experiments by using
the Monte-Carlo method. They allow you to save the simulation results in SQL databases and then generate a report 
or a set of reports consisting of HTML pages with charts, histograms, links to CSV tables, summary statistics etc.
Please consult the [AivikaSoft](http://www.aivikasoft.com) website for more details.

Regarding the speed of simulation, the recent rough estimation is as follows. This estimation may change from 
version to version. For example, in version 1.0 the rollback log was rewritten, which had a significant effect.

When simulating sequential models, the speed of single logical process of the distributed module in comparison with 
the sequential [aivika](http://hackage.haskell.org/package/aivika) module varies and depends essentially on the number of 
simultaneously processed discrete events, or the number of simultaneously running discontinuous processes, 
which is very close. If there are many simultaneous events, then the distributed module can be slower in 4-5 times only. 
The more simultaneous events are defined in the model, the less is a gap in the speed between modules.
But if the simultaneous events are rare, then the distributed module can be slower even in 15 times, 
where the sequential module can be exceptionally fast. At the same time, the message passing between the logical 
processes can dramatically decrease the speed of distributed simulation, especially if the messages cause rollbacks. 
Then it makes sense to define the time horizon parameter. Thus, much depends on the distributed model itself.

When residing the logical processes in a computer with multi-core processor, you should follow the next recommendations. 
You should reserve at least 1 core for each logical process, or even reserve 2 cores if the logical process extensively 
sends and receives messages. Also you should additionally reserve at least 1 or 2 cores for each computational node. 
These additional processor cores will be used by the GHC run-time system that includes the garbage collector as well. 
The Aivika distributed module creates a huge amount of short-living small objects. Therefore, the garbage collector 
needs at least one core to utilize efficiently these objects.

You should compile your code with options `-O2 -threaded`, but then launch it with run-time options `+RTS -N`.
