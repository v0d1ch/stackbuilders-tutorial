{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE TupleSections      #-}

module Main where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.ManagedProcess hiding (ChannelHandler, runProcess)
import Control.Distributed.Process.Node (runProcess, newLocalNode, initRemoteTable)
import Control.Distributed.Process.Extras.Time (Delay (..))
import Control.Monad (forever, forM_, void)
import Data.Binary
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map as M
import Data.Typeable hiding (cast)
import GHC.Generics
import Network.Transport.TCP
import Network.Transport hiding (send)

type NickName = String
type ChatName = String
type ServerAddress = String
type Host = String
type ClientPortMap = M.Map NickName (SendPort ChatMessage)
type ChannelHandler state msg1 msg2 = SendPort msg2 -> (state -> msg1 -> Action state)

newtype JoinChatMessage = JoinChatMessage {
    clientName :: NickName
  } deriving (Generic, Typeable, Show)

instance Binary JoinChatMessage
data Sender = Server | Client NickName
  deriving (Generic, Typeable, Eq, Show)

instance Binary Sender

data ChatMessage = ChatMessage {
    from :: Sender
  , message :: String
  } deriving (Generic, Typeable, Show)

instance Binary ChatMessage

main :: IO ()
main = do
  Right transport <- createTransport "127.0.0.1" "4001" ("127.0.0.1", ) defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  _ <- runProcess node $ do
    -- get the id of this process
    self <- getSelfPid
    send self "Talking to myself"
    message <- expect :: Process String
    liftIO $ putStrLn message
  return ()

launchChatServer :: Process ProcessId
launchChatServer =
  let server = defaultProcess {
          apiHandlers =  [ handleRpcChan joinChatHandler
                         , handleCast messageHandler
                         ]
        , infoHandlers = [ handleInfo disconnectHandler ]
        , unhandledMessagePolicy = Log
        }
  in spawnLocal $ serve () (const (return $ InitOk M.empty Infinity)) server

joinChatHandler :: ChannelHandler ClientPortMap JoinChatMessage ChatMessage
joinChatHandler sendPort = handler
  where
    handler :: ActionHandler ClientPortMap JoinChatMessage
    handler clients JoinChatMessage{..} =
      if clientName `M.member` clients
      then replyChan sendPort (ChatMessage Server "Nickname already in use ... ") >> continue clients
        else do
          void $ monitorPort sendPort
          let clients' = M.insert clientName sendPort clients
              msg = clientName ++ " has joined the chat ..."
          -- logStr msg
          broadcastMessage clients $ ChatMessage Server msg
          continue clients'

broadcastMessage :: ClientPortMap -> ChatMessage -> Process ()
broadcastMessage clientPorts msg =
  forM_ clientPorts (flip replyChan msg)

messageHandler :: CastHandler ClientPortMap ChatMessage
messageHandler = handler
  where
    handler :: ActionHandler ClientPortMap ChatMessage
    handler clients msg = do
      broadcastMessage clients msg
      continue clients

disconnectHandler :: ActionHandler ClientPortMap PortMonitorNotification
disconnectHandler clients (PortMonitorNotification _ spId reason) = do
  let search = M.filter (\v -> sendPortId v == spId) clients
  case (null search, reason) of
    (False, DiedDisconnect)-> do
      let (clientName, _) = M.elemAt 0 search
          clients' = M.delete clientName clients
      broadcastMessage clients' (ChatMessage Server $ clientName ++ " has left the chat ... ")
      continue clients'
    _ -> continue clients

searchChatServer :: ChatName -> ServerAddress -> Process ProcessId
searchChatServer name serverAddr = do
  let addr = EndPointAddress (BS.pack serverAddr)
      srvId = NodeId addr
  whereisRemoteAsync srvId name
  reply <- expectTimeout 1000
  case reply of
    Just (WhereIsReply _ (Just sid)) -> return sid
    _ -> searchChatServer name serverAddr

launchChatClient :: ServerAddress -> Host -> Int -> ChatName -> IO ()
launchChatClient serverAddr clientHost port name  = do
  mt <- createTransport clientHost (show port) (clientHost,) defaultTCPParameters
  case mt of
    Left err -> putStrLn (show err)
    Right transport -> do
      node <- newLocalNode transport initRemoteTable
      -- runChatLogger node
      runProcess node $ do
        serverPid <- searchChatServer name serverAddr
        link serverPid
        -- logStr "Joining chat server ... "
        -- logStr "Please, provide your nickname ... "
        nickName <- liftIO getLine
        rp <- callChan serverPid (JoinChatMessage nickName) :: Process (ReceivePort ChatMessage)
        -- logStr "You have joined the chat ... "
        void $ spawnLocal $ forever $ do
          msg <- receiveChan rp
          -- logChatMessage msg
          return ()
        forever $ do
          chatInput <- liftIO getLine
          cast serverPid (ChatMessage (Client nickName) chatInput)
          liftIO $ threadDelay 500000
