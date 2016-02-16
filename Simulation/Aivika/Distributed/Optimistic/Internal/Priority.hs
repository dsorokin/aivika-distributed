
{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Priority
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines the logging 'Priority'.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Priority
       (Priority(..)) where

import Data.Typeable
import Data.Binary

import GHC.Generics

-- | The logging priority.
data Priority = DEBUG
                -- ^ Debug messages
              | INFO
                -- ^ Information
              | NOTICE
                -- ^ Normal runtime conditions
              | WARNING
                -- ^ Warnings
              | ERROR
                -- ^ Errors
              deriving (Eq, Ord, Show, Read, Typeable, Generic)

instance Binary Priority


