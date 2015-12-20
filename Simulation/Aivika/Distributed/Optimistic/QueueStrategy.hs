
{-# LANGUAGE TypeFamilies, MultiParamTypeClasses #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.QueueStrategy
-- Copyright  : Copyright (c) 2009-2015, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines some queue strategy instances.
--
module Simulation.Aivika.Distributed.Optimistic.QueueStrategy where

import Control.Monad.Trans

import Simulation.Aivika.Trans
import qualified Simulation.Aivika.Trans.DoubleLinkedList as LL
import Simulation.Aivika.Distributed.Optimistic.Internal.DIO
import Simulation.Aivika.Distributed.Optimistic.Ref.Base

-- | An implementation of the 'FCFS' queue strategy.
instance QueueStrategy DIO FCFS where

  -- | A queue used by the 'FCFS' strategy.
  newtype StrategyQueue DIO FCFS a = FCFSQueue (LL.DoubleLinkedList DIO a)

  newStrategyQueue s = fmap FCFSQueue LL.newList

  strategyQueueNull (FCFSQueue q) = LL.listNull q

-- | An implementation of the 'FCFS' queue strategy.
instance DequeueStrategy DIO FCFS where

  strategyDequeue (FCFSQueue q) =
    do i <- LL.listFirst q
       LL.listRemoveFirst q
       return i

-- | An implementation of the 'FCFS' queue strategy.
instance EnqueueStrategy DIO FCFS where

  strategyEnqueue (FCFSQueue q) i = LL.listAddLast q i

-- | An implementation of the 'LCFS' queue strategy.
instance QueueStrategy DIO LCFS where

  -- | A queue used by the 'LCFS' strategy.
  newtype StrategyQueue DIO LCFS a = LCFSQueue (LL.DoubleLinkedList DIO a)

  newStrategyQueue s = fmap LCFSQueue LL.newList
       
  strategyQueueNull (LCFSQueue q) = LL.listNull q

-- | An implementation of the 'LCFS' queue strategy.
instance DequeueStrategy DIO LCFS where

  strategyDequeue (LCFSQueue q) =
    do i <- LL.listFirst q
       LL.listRemoveFirst q
       return i

-- | An implementation of the 'LCFS' queue strategy.
instance EnqueueStrategy DIO LCFS where

  strategyEnqueue (LCFSQueue q) i = LL.listInsertFirst q i
