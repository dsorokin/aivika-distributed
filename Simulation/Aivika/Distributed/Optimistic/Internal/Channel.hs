
-- |
-- Module     : Simulation.Aivika.Distributed.Optimistic.Internal.Channel
-- Copyright  : Copyright (c) 2015-2016, David Sorokin <david.sorokin@gmail.com>
-- License    : BSD3
-- Maintainer : David Sorokin <david.sorokin@gmail.com>
-- Stability  : experimental
-- Tested with: GHC 7.10.3
--
-- This module defines a channel with fast checking procedure whether the channel is empty.
--
module Simulation.Aivika.Distributed.Optimistic.Internal.Channel
       (Channel,
        newChannel,
        channelEmpty,
        readChannel,
        writeChannel,
        awaitChannel) where

import Data.List
import Data.IORef

import Control.Concurrent.STM
import Control.Monad

-- | A channel.
data Channel a =
  Channel { channelList :: TVar ([a] -> [a]),
            channelListEmpty :: TVar Bool,
            channelListEmptyIO :: IORef Bool
          }

-- | Create a new channel.
newChannel :: IO (Channel a)
newChannel =
  do list <- newTVarIO id
     listEmpty <- newTVarIO True
     listEmptyIO <- newIORef True
     return Channel { channelList = list,
                      channelListEmpty = listEmpty,
                      channelListEmptyIO = listEmptyIO }

-- | Test quickly whether the channel is empty.
channelEmpty :: Channel a -> IO Bool
channelEmpty ch =
  readIORef (channelListEmptyIO ch)

-- | Read all data from the channel. 
readChannel :: Channel a -> IO [a]
readChannel ch =
  do empty <- readIORef (channelListEmptyIO ch)
     if empty
       then return []
       else do writeIORef (channelListEmptyIO ch) True
               f <- atomically $
                    do f <- readTVar (channelList ch)
                       writeTVar (channelList ch) id
                       writeTVar (channelListEmpty ch) True
                       return f
               return (f [])

-- | Write the value in the channel.
writeChannel :: Channel a -> a -> IO ()
writeChannel ch a =
  do atomically $
       do f <- readTVar (channelList ch)
          let f' xs = a : f xs
          writeTVar (channelList ch) f'
          writeTVar (channelListEmpty ch) False
     writeIORef (channelListEmptyIO ch) False

-- | Wait for data in the channel.
awaitChannel :: Channel a -> IO ()
awaitChannel ch =
  atomically $
  do empty <- readTVar (channelListEmpty ch)
     when empty retry
