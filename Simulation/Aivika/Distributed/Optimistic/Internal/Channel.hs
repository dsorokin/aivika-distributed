
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

import Data.IORef

import Control.Concurrent.MVar

import qualified Simulation.Aivika.DoubleLinkedList as DLL

-- | A channel.
data Channel a =
  Channel { channelLock :: MVar (),
            channelCond :: MVar (),
            channelList :: IORef (DLL.DoubleLinkedList a),
            channelListEmpty :: IORef Bool
          }

-- | Create a new channel.
newChannel :: IO (Channel a)
newChannel =
  do lock <- newMVar ()
     cond <- newEmptyMVar
     list <- DLL.newList >>= newIORef
     listEmpty <- newIORef True
     return Channel { channelLock = lock,
                      channelCond = cond,
                      channelList = list,
                      channelListEmpty = listEmpty }

-- | Test quickly whether the channel is empty.
channelEmpty :: Channel a -> IO Bool
channelEmpty ch =
  readIORef (channelListEmpty ch)

-- | Read all data from the channel. 
readChannel :: Channel a -> IO [a]
readChannel ch =
  withMVar (channelLock ch) $ \() ->
  do f <- readIORef (channelListEmpty ch)
     if f
       then return []
       else do list  <- readIORef (channelList ch)
               list' <- DLL.newList
               writeIORef (channelList ch) list'
               writeIORef (channelListEmpty ch) True
               tryTakeMVar (channelCond ch)
               DLL.freezeList list

-- | Write the value in the channel.
writeChannel :: Channel a -> a -> IO ()
writeChannel ch a =
  withMVar (channelLock ch) $ \() ->
  do list <- readIORef (channelList ch)
     DLL.listAddLast list a
     writeIORef (channelListEmpty ch) False
     tryPutMVar (channelCond ch) ()
     return ()

-- | Wait for data in the channel.
awaitChannel :: Channel a -> IO ()
awaitChannel ch = takeMVar (channelCond ch)
