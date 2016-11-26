A parallel distributed discrete event simulation module for the Aivika library

The represented [aivika-distributed] [2] package extends the [aivika-transformers] [1]
package and allows running the parallel distributed discrete event simulations.

It is inspired by ideas of the Time Warp algorithm. The library implements
an optimistic strategy with capabilities of transparent rollbacks. To synchronize 
the global virtual time, since version 0.3 it uses Samadi's algorithm.

[1]: http://hackage.haskell.org/package/aivika-transformers  "aivika-transformers"
[2]: http://hackage.haskell.org/package/aivika-distributed  "aivika-distributed"
