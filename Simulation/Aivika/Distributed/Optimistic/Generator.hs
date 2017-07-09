
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Generator
-- Copyright  : Copyright (c) 2015-2017, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- Here is defined a random number generator,
-- where 'DIO' is an instance of 'MonadGenerator'.
--
module Simulation.Aivika.Distributed.Optimistic.Generator () where

import Control.Monad
import Control.Monad.Trans

import System.Random
import qualified System.Random.MWC as MWC

import Data.IORef

import Simulation.Aivika.Trans
import Simulation.Aivika.Trans.Generator.Primitive

import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Internal.IO

instance MonadGenerator DIO where

  data Generator DIO =
    Generator { generator01 :: DIO Double,
                -- ^ the generator of uniform numbers from 0 to 1
                generatorNormal01 :: DIO Double,
                -- ^ the generator of normal numbers with mean 0 and variance 1
                generatorSequenceNo :: DIO Int
                -- ^ the generator of sequence numbers
              }

  generateUniform = generateUniform01 . generator01

  generateUniformInt = generateUniformInt01 . generator01

  generateTriangular = generateTriangular01 . generator01

  generateNormal = generateNormal01 . generatorNormal01

  generateLogNormal = generateLogNormal01 . generatorNormal01

  generateExponential = generateExponential01 . generator01

  generateErlang = generateErlang01 . generator01

  generatePoisson = generatePoisson01 . generator01

  generateBinomial = generateBinomial01 . generator01

  generateGamma g = generateGamma01 (generatorNormal01 g) (generator01 g)

  generateBeta g = generateBeta01 (generatorNormal01 g) (generator01 g)

  generateWeibull = generateWeibull01 . generator01

  generateDiscrete = generateDiscrete01 . generator01

  generateSequenceNo = generatorSequenceNo

  newGenerator tp =
    case tp of
      SimpleGenerator ->
        do let g = MWC.uniform <$>
                   MWC.withSystemRandom (return :: MWC.GenIO -> IO MWC.GenIO)
           g' <- liftIOUnsafe g
           newRandomGenerator01 (liftIOUnsafe g')
      SimpleGeneratorWithSeed x ->
        error "Unsupported generator type SimpleGeneratorWithSeed: newGenerator"
      CustomGenerator g ->
        g
      CustomGenerator01 g ->
        newRandomGenerator01 g

  newRandomGenerator g = 
    do r <- liftIOUnsafe $ newIORef g
       let g01 = do g <- liftIOUnsafe $ readIORef r
                    let (x, g') = random g
                    liftIOUnsafe $ writeIORef r g'
                    return x
       newRandomGenerator01 g01

  newRandomGenerator01 g01 =
    do gNormal01 <- newNormalGenerator01 g01
       gSeqNoRef <- liftIOUnsafe $ newIORef 0
       let gSeqNo =
             do x <- liftIOUnsafe $ readIORef gSeqNoRef
                liftIOUnsafe $ modifyIORef' gSeqNoRef (+1)
                return x
       return Generator { generator01 = g01,
                          generatorNormal01 = gNormal01,
                          generatorSequenceNo = gSeqNo }

-- | Create a normal random number generator with mean 0 and variance 1
-- by the specified generator of uniform random numbers from 0 to 1.
newNormalGenerator01 :: DIO Double
                        -- ^ the generator
                        -> DIO (DIO Double)
newNormalGenerator01 g =
  do nextRef <- liftIOUnsafe $ newIORef 0.0
     flagRef <- liftIOUnsafe $ newIORef False
     xi1Ref  <- liftIOUnsafe $ newIORef 0.0
     xi2Ref  <- liftIOUnsafe $ newIORef 0.0
     psiRef  <- liftIOUnsafe $ newIORef 0.0
     let loop =
           do psi <- liftIOUnsafe $ readIORef psiRef
              if (psi >= 1.0) || (psi == 0.0)
                then do g1 <- g
                        g2 <- g
                        let xi1 = 2.0 * g1 - 1.0
                            xi2 = 2.0 * g2 - 1.0
                            psi = xi1 * xi1 + xi2 * xi2
                        liftIOUnsafe $ writeIORef xi1Ref xi1
                        liftIOUnsafe $ writeIORef xi2Ref xi2
                        liftIOUnsafe $ writeIORef psiRef psi
                        loop
                else liftIOUnsafe $ writeIORef psiRef $ sqrt (- 2.0 * log psi / psi)
     return $
       do flag <- liftIOUnsafe $ readIORef flagRef
          if flag
            then do liftIOUnsafe $ writeIORef flagRef False
                    liftIOUnsafe $ readIORef nextRef
            else do liftIOUnsafe $ writeIORef xi1Ref 0.0
                    liftIOUnsafe $ writeIORef xi2Ref 0.0
                    liftIOUnsafe $ writeIORef psiRef 0.0
                    loop
                    xi1 <- liftIOUnsafe $ readIORef xi1Ref
                    xi2 <- liftIOUnsafe $ readIORef xi2Ref
                    psi <- liftIOUnsafe $ readIORef psiRef
                    liftIOUnsafe $ writeIORef flagRef True
                    liftIOUnsafe $ writeIORef nextRef $ xi2 * psi
                    return $ xi1 * psi
