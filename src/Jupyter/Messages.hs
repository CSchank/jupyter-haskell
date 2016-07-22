{-|
Module      : Jupyter.Messages
Description : A type-safe specification for the Jupyter messaging specification.
Copyright   : (c) Andrew Gibiansky, 2016
License     : MIT
Maintainer  : andrew.gibiansky@gmail.com
Stability   : stable
Portability : POSIX

Jupyter kernels and clients communicate along a typed messaging protocol called the /Jupyter messaging protocol/.
The protocol defines several ZeroMQ sockets that are used for communication between the clients and the kernels, 
as well as the format of the data that is sent on each of those sockets.

To summarize briefly, the messaging protocol defines four types of communication:
  * Client to kernel requests ('ClientRequest') and replies ('KernelReply')
  * Kernel output publication to all clients ('KernelOutput')
  * Kernel to client requests ('KernelRequest') and replies ('ClientReply')
  * Free-form "comm" messages between kernels and clients ('Comm')

Client to kernel requests and replies are sent on two sockets called the /shell/ and /control/ sockets, but 
when using the @jupyter-kernel@ package these two sockets can be treated as a single communication channel,
with the caveat that two messages may be sent at once (and thus the handlers must be thread-safe). Clients will
send a 'ClientRequest' which the kernel must respond to with a 'KernelReply'.

During the response, kernels may want to publish results, intermediate data, or errors to the front-end(s).
This is done on the /iopub/ socket, with every published value corresponding to a 'KernelOutput'. Kernel
outputs are the primary mechanism for transmitting results of code evaluation to the front-ends.

In addition to publishing outputs, kernels may request input from the clients during code evaluation using 'KernelRequest' messages, to which the clients reply with a 'ClientReply'. At the moment, the
only use for 'KernelRequest's is to request standard input from the clients, so all such messages go on the /stdin/ socket.

Finally, kernels and frontends can create custom communication protocols using the free-form and unstructured 'Comm'
messages. A comm in Jupyter parlance is a communication channel between a kernel and a client; either one
may request to create or close a comm, and then send arbitrary JSON data along that comm. Kernels listen
for 'Comm' messages on the /shell/ socket and can send their own 'Comm' messages on the /iopub/ socket.

For more information, please read the <https://jupyter-client.readthedocs.io/en/latest/messaging.html full Jupyter messaging specification>.

-}

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternSynonyms #-}
module Jupyter.Messages (
    -- * All messages
    Client,
    Kernel,
    Message(..),
    messageHeader,

    -- * Client Requests (Shell channel)
    ClientRequest(..),
    CodeBlock(..),
    CodeOffset(..),
    ExecuteOptions(..),
    DetailLevel(..),
    HistoryOptions(..),
    TargetName(..),
    Restart(..),
    HistoryAccessType(..),
    HistoryRangeOptions(..),
    HistorySearchOptions(..),

    -- * Kernel Replies (Shell channel)
    KernelReply(..),
    KernelInfo(..),
    LanguageInfo(..),
    HelpLink(..),
    ExecuteResult(..),
    pattern ExecuteOk,
    pattern ExecuteError,
    pattern ExecuteAbort,
    InspectResult(..),
    pattern InspectOk,
    pattern InspectError,
    pattern InspectAbort,
    CompleteResult(..),
    pattern CompleteOk,
    pattern CompleteError,
    pattern CompleteAbort,
    CompletionMatch(..),
    CursorRange(..),
    OperationResult(..),
    HistoryItem(..),
    ExecutionCount(..),
    CodeComplete(..),
    ConnectInfo(..),

    -- * Kernel Outputs (IOPub channel)
    KernelOutput(..),
    Stream(..),
    DisplayData(..),
    ImageDimensions(..),
    MimeType(..),
    ErrorInfo(..),
    WaitBeforeClear(..),
    KernelStatus(..),

    -- * Kernel Requests (Stdin channel)
    KernelRequest(..),
    InputOptions(..),

    -- * Client Replies (Stdin channel)
    ClientReply(..),

    -- * Comm Messages (Shell or IOPub channel)
    Comm(..),
    TargetModule(..),
    ) where

import           Data.Text (Text)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Aeson (Value(..), (.=), object, FromJSON, ToJSON(..))
import           Data.ByteString (ByteString)
import           Data.List (intercalate)

import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           GHC.Exts (IsString)

import           Jupyter.Messages.Metadata (IsMessage(..), MessageHeader)
import           Jupyter.UUID (UUID, uuidToString)

-- | Phantom type used to denote messages sent by clients (see 'Message').
data Client

-- | Phantom type used to denote messages sent by kernels (see 'Message').
data Kernel

-- | A sum type representing all Jupyter messages, tagged with their sender application type.
--
-- @'Message' 'Client'@ messages are sent by clients (frontends), whereas @'Message' 'Kernel'@
-- messages are sent by kernels (often in reply to client messages).
--
-- Unlike most messages, 'Comm' messages can be either @'Message' 'Client'@ or @'Message' 'Kernel'@,
-- since both kernels and clients can send 'Comm' messages.
data Message s where
        Comm :: MessageHeader -> Comm -> Message s 
        ClientRequest :: MessageHeader -> ClientRequest -> Message Client
        ClientReply :: MessageHeader -> ClientReply -> Message Client
        KernelRequest :: MessageHeader -> KernelRequest -> Message Kernel
        KernelReply :: MessageHeader -> KernelReply -> Message Kernel
        KernelOutput :: MessageHeader -> KernelOutput -> Message Kernel

-- | Extract the 'MessageHeader' from any message.
messageHeader :: Message s -> MessageHeader
messageHeader msg =
  case msg of
    Comm h _          -> h
    ClientRequest h _ -> h
    ClientReply h _   -> h
    KernelRequest h _ -> h
    KernelReply h _   -> h
    KernelOutput h _  -> h

-- | Most communication from a client to a kernel is initiated by the client on the /shell/ socket.
--
-- The /shell/ socket accepts multiple incoming connections from different frontends (clients), and
-- receives requests for code execution, object information, prompts, etc. from all the connected
-- frontends. The communication on this socket is a sequence of request/reply actions from each
-- frontend and the kernel.
--
-- The clients will send 'ClientRequest' messages to the kernel, to which the kernel must reply with
-- exactly one appropriate 'KernelReply' and, optionally, publish as many 'KernelOutput's as the
-- kernel wishes. Each 'ClientRequest' constructor corresponds to exactly one 'KernelReply'
-- constructor which should be used in the reply.
--
-- For more information on each of these messages, view the appropriate section <https://jupyter-client.readthedocs.io/en/latest/messaging.html#messages-on-the-shell-router-dealer-sockets of the Jupyter messaging spec>.

data ClientRequest =
                   -- | This message type is used by frontends to ask the kernel to execute code on
                   -- behalf of the user, in a namespace reserved to the user’s variables (and thus
                   -- separate from the kernel’s own internal code and variables).
                    ExecuteRequest CodeBlock ExecuteOptions
                   |
                   -- | Code can be inspected to show useful information to the user. It is up to
                   -- the kernel to decide what information should be displayed, and its
                   -- formatting.
                   --
                   -- The reply is a mime-bundle, like a 'DisplayData' message, which should be a
                   -- formatted representation of information about the context. In the notebook,
                   -- this is used to show tooltips over function calls, etc.
                    InspectRequest CodeBlock CodeOffset DetailLevel
                   |
                   -- | For clients to explicitly request history from a kernel. The kernel has all
                   -- the actual execution history stored in a single location, so clients can
                   -- request it from the kernel when needed.
                    HistoryRequest HistoryOptions
                   |
                   -- | A message type for the client to request autocompletions from the kernel.
                   --
                   -- The lexing is left to the kernel, and the only information provided is the
                   -- cell contents and the current cursor location in the cell.
                    CompleteRequest CodeBlock CodeOffset
                   |
                   -- | When the user enters a line in a console style interface, the console must
                   -- decide whether to immediately execute the current code, or whether to show a
                   -- continuation prompt for further input. For instance, in Python @a = 5@ would
                   -- be executed immediately, while for @i in range(5):@ would expect further
                   -- input.
                   --
                   -- There are four possible replies (see the 'CodeComplete' data type): 
                   --
                   --   * /complete/: code is ready to be executed
                   --   * /incomplete/: code should prompt for another line
                   -- * /invalid/: code will typically be sent for execution, so that the user sees
                   -- the error soonest.
                   --   * /unknown/: if the kernel is not able to determine this.
                   --
                   -- The frontend should also handle the kernel not replying promptly. It may
                   -- default to sending the code for execution, or it may implement simple
                   -- fallback heuristics for whether to execute the code (e.g. execute after a
                   -- blank line). Frontends may have ways to override this, forcing the code to be
                   -- sent for execution or forcing a continuation prompt.
                    IsCompleteRequest CodeBlock
                   |
                   -- | When a client connects to the request/reply socket of the kernel, it can
                   -- issue a connect request to get basic information about the kernel, such as
                   -- the ports the other ZeroMQ sockets are listening on. This allows clients to
                   -- only have to know about a single port (the shell channel) to connect to a
                   -- kernel.
                    ConnectRequest
                   |
                   -- | When a client needs the currently open @comm@s in the kernel, it can issue
                   -- a 'CommInfoRequest' for the currently open @comm@s. When the optional
                   -- 'TargetName' is specified, the 'CommInfoReply' should only contain the
                   -- currently open @comm@s for that target.
                    CommInfoRequest (Maybe TargetName)
                   |
                   -- | If a client needs to know information about the kernel, it can make a
                   -- 'KernelInfoRequest'. This message can be used to fetch core information of
                   -- the kernel, including language (e.g., Python), language version number and
                   -- IPython version number, and the IPython message spec version number.
                    KernelInfoRequest
                   |
                   -- | The clients can request the kernel to shut itself down; this is used in
                   -- multiple cases:
                   --
                   -- * when the user chooses to close the client application via a menu or window
                   -- control. * when the user invokes a frontend-specific exit method (like the
                   -- 'quit' magic) * when the user chooses a GUI method (like the ‘Ctrl-C’
                   -- shortcut in the IPythonQt client) to force a kernel restart to get a clean
                   -- kernel without losing client-side state like history or inlined figures.
                   --
                   -- The client sends a shutdown request to the kernel, and once it receives the
                   -- reply message (which is otherwise empty), it can assume that the kernel has
                   -- completed shutdown safely. The request can be sent on either the /control/ or
                   -- /shell/ sockets. Upon their own shutdown, client applications will typically
                   -- execute a last minute sanity check and forcefully terminate any kernel that
                   -- is still alive, to avoid leaving stray processes in the user’s machine.
                    ShutdownRequest Restart
  deriving (Eq, Ord, Show)

instance IsMessage ClientRequest where
  getMessageType req =
    case req of
      ExecuteRequest{}    -> "execute_request"
      InspectRequest{}    -> "inspect_request"
      HistoryRequest{}    -> "history_request"
      CompleteRequest{}   -> "complete_request"
      IsCompleteRequest{} -> "is_complete_request"
      ConnectRequest{}    -> "connect_request"
      CommInfoRequest{}   -> "comm_info_request"
      KernelInfoRequest{} -> "kernel_info_request"
      ShutdownRequest{}   -> "shutdown_request"

instance ToJSON ClientRequest where
  toJSON req =
    object $
      case req of
        ExecuteRequest code ExecuteOptions { .. } ->
          [ "code" .= code
          , "silent" .= executeSilent
          , "store_history" .= executeStoreHistory
          , "allow_stdin" .= executeAllowStdin
          , "stop_on_error" .= executeStopOnError
          , "user_expressions" .= (Map.fromList [] :: Map.Map Text ())
          ]
        InspectRequest code offset detail ->
          ["code" .= code, "cursor_pos" .= offset, "detail_level" .= detail]
        CompleteRequest code offset -> ["code" .= code, "cursor_pos" .= offset]
        HistoryRequest HistoryOptions { .. } ->
          ["output" .= historyShowOutput, "raw" .= historyRaw] ++
          case historyAccessType of
            HistoryRange HistoryRangeOptions { .. } ->
              [ "hist_access_type" .= ("range" :: String)
              , "session" .= historyRangeSession
              , "start" .= historyRangeStart
              , "stop" .= historyRangeStop
              ]
            HistoryTail n -> ["hist_access_type" .= ("tail" :: String), "n" .= n]
            HistorySearch HistorySearchOptions { .. } ->
              [ "hist_access_type" .= ("search" :: String)
              , "n" .= historySearchCells
              , "pattern" .= historySearchPattern
              , "unique" .= historySearchUnique
              ]
        IsCompleteRequest code -> ["code" .= code]
        ConnectRequest{} -> []
        CommInfoRequest targetName ->
          case targetName of
            Nothing   -> []
            Just name -> ["target_name" .= name]
        KernelInfoRequest{} -> []
        ShutdownRequest restart -> ["restart" .= restart]


-- | Options for executing code in the kernel.
data ExecuteOptions =
       ExecuteOptions
         { executeSilent :: Bool
         -- ^ Whether this code should be forced to be as silent as possible.
         --
         -- Kernels should avoid broadcasting on the /iopub/ channel (sending 'KernelOutput' messages) and
         -- the 'ExecuteReply' message will not be sent when 'executeSilent' is @True@. In addition, kernels
         -- should act as if 'executeStoreHistory' is set to @True@ whenever 'executeSilent' is @True@.
         , executeStoreHistory :: Bool
         -- ^ A boolean flag which, if @True@, signals the kernel to populate its history. If 'executeSilent'
         -- is @True@, kernels should ignore the value of this flag and treat it as @False@.
         , executeAllowStdin :: Bool
         -- ^ Some frontends do not support @stdin@ requests.
         --
         -- If such a frontend makes a request, it should set 'executeAllowStdin' to @False@, and any code
         -- that reads from @stdin@ should crash (or, if the kernel so desires, get an empty string).
         , executeStopOnError :: Bool -- ^ A boolean flag, which, if @True@, does not abort the
                                      -- execution queue, if an exception or error is encountered.
                                      -- This allows the queued execution of multiple
                                      -- execute_requests, even if they generate exceptions.
         }
  deriving (Eq, Ord, Show)


-- | Whether the kernel should restart after shutting down, or remain stopped.
data Restart =
             -- | Restart after shutting down.
              Restart
             |
             -- | Remain stopped after shutting down.
              NoRestart
  deriving (Eq, Ord, Show)

instance ToJSON Restart where
  toJSON Restart = Bool True
  toJSON NoRestart = Bool False

-- | The target name (@target_name@) for a 'Comm'.
--
-- The target name is, roughly, the type of the @comm@ to open. It tells the kernel or the frontend
-- (whichever receives the 'CommOpen' message) what sort of @comm@ to open and how that @comm@
-- should behave. (The 'TargetModule' can also be optionally used in combination with a 'TargetName'
-- for this purpose; see 'CommOpen' for more info.)
newtype TargetName = TargetName Text 
  deriving (Eq, Ord, Show, FromJSON, ToJSON)

-- | A block of code, represented as text.
newtype CodeBlock = CodeBlock Text
  deriving (Eq, Ord, Show, FromJSON, ToJSON)

-- | A zero-indexed offset into a block of code.
newtype CodeOffset = CodeOffset Int
  deriving (Eq, Ord, Show, Num, FromJSON, ToJSON)

-- | How much detail to show for an 'InspectRequest'.
data DetailLevel = DetailLow  -- ^ Include a low level of detail. In IPython, 'DetailLow' is
                              -- equivalent to typing @x?@ at the prompt.
                 | DetailHigh  -- ^ Include a high level of detail. In IPython, 'DetailHigh' is
                               -- equivalent to typing @x??@ at the prompt, and tries to include the
                               -- source code.
  deriving (Eq, Ord, Show)

instance ToJSON DetailLevel where
  toJSON DetailLow = Number 0
  toJSON DetailHigh = Number 1

-- | What to search for in the kernel history.
data HistoryOptions =
       HistoryOptions
         { historyShowOutput :: Bool -- ^ If @True@, include text output in the resulting 'HistoryItem's.
         , historyRaw :: Bool -- ^ If @True@, return the raw input history, else the transformed input.
         , historyAccessType :: HistoryAccessType -- ^ Type of search to perform.
         }
  deriving (Eq, Ord, Show)

-- | What items should be accessed in this 'HistoryRequest'.
data HistoryAccessType = HistoryRange HistoryRangeOptions -- ^ Get a range of history items.
                       | HistoryTail Int  -- ^ Get the last /n/ cells in the history.
                       | HistorySearch HistorySearchOptions -- ^ Search for something in the history.
  deriving (Eq, Ord, Show)

-- | Options for retrieving a range of history cells.
data HistoryRangeOptions =
       HistoryRangeOptions
         { historyRangeSession :: Int -- ^ Which cell to retrieve history for. If this is negative,
                                      -- then it counts backwards from the current session.
         , historyRangeStart :: Int -- ^ Which item to start with in the selected session.
         , historyRangeStop :: Int -- ^ Which item to end with in the selected session.
         }
  deriving (Eq, Ord, Show)

-- | Options for retrieving history cells that match a pattern.
data HistorySearchOptions =
       HistorySearchOptions
         { historySearchCells :: Int -- ^ Get the last /n/ cells that match the provided pattern.
         , historySearchPattern :: Text -- ^ Pattern to search for (treated literally but with @*@
                                        -- and @?@ as wildcards).
         , historySearchUnique :: Bool -- ^ If @True@, do not include duplicated history items.
         }
  deriving (Eq, Ord, Show)

-- | Clients send requests ('ClientRequest') to the kernel via the /shell/ socket, and kernels
-- generate one 'KernelReply' as a response to every 'ClientRequest'. Each type of 'ClientRequest'
-- corresponds to precisely one response type (for example, 'HistoryRequest' must be responded to
-- with a 'HistoryReply').
data KernelReply =
                 -- | If a client needs to know information about the kernel, it can make a request
                 -- of the kernel’s information, which must be responded to with a
                 -- 'KernelInfoReply'. This message can be used to fetch core information of the
                 -- kernel, including language (e.g., Python), language version number and IPython
                 -- version number, and the IPython message spec version number.
                  KernelInfoReply KernelInfo
                 |
                 -- | Reply to an 'ExecuteRequest' message.
                 --
                 -- The kernel should have a single, monotonically increasing counter of all
                 -- execution requests that are made with when @executeStoreHistory@ is @True@.
                 -- This counter is used to populate the @In[n]@ and @Out[n]@ prompts in the
                 -- frontend. The value of this counter will be returned as the 'ExecutionCount'
                 -- field of all 'ExecuteReply' and 'ExecuteInput' messages.
                 --
                 -- 'ExecuteReply' does not include any output data, only a status, as the output
                 -- data is sent via 'DisplayData' messages on the /iopub/ channel (in
                 -- 'KernelOutput' messages).
                  ExecuteReply ExecuteResult ExecutionCount
                 |
                 -- | Code can be inspected to show useful information to the user. It is up to the
                 -- kernel to decide what information should be displayed, and its formatting.
                 --
                 -- The reply is a mime-bundle, like a 'DisplayData' message, which should be a
                 -- formatted representation of information about the context. In the notebook,
                 -- this is used to show tooltips over function calls, etc.
                  InspectReply InspectResult
                 |
                 -- | Clients can explicitly request history from a kernel. The kernel has all the
                 -- actual execution history stored in a single location, so clients can request it
                 -- from the kernel when needed.
                 --
                 -- The 'HistoryItem's should include non-@Nothing@ 'historyItemOutput' values when
                 -- 'historyShowOutput' in the 'HistoryRequest' is @True@.
                  HistoryReply [HistoryItem]
                 |
                 -- | Clients can request autocompletion results from the kernel, and the kernel
                 -- responds with a list of matches and the selection to autocomplete.
                  CompleteReply CompleteResult
                 |
                 -- | Clients can request the code completeness status with a 'IsCompleteRequest'.
                 --
                 -- For example, when the user enters a line in a console style interface, the
                 -- console must decide whether to immediately execute the current code, or whether
                 -- to show a continuation prompt for further input. For instance, in Python @a =
                 -- 5@ would be executed immediately, while @for i in range(5):@ would expect
                 -- further input.
                  IsCompleteReply CodeComplete
                 |
                 -- | When a client connects to the request/reply socket of the kernel, it can
                 -- issue a 'ConnectRequest' to get basic information about the kernel, such as the
                 -- ports the other ZeroMQ sockets are listening on. This allows clients to only
                 -- have to know about a single port (the shell channel) to connect to a kernel.
                 --
                 -- The 'ConnectReply' contains a 'ConnectInfo' with information about the ZeroMQ
                 -- sockets' ports used by the kernel.
                  ConnectReply ConnectInfo
                 |
                 -- | When a client needs the currently open comms in the kernel, it can issue a
                 -- 'CommInfoRequest' for the currently open comms.
                 --
                 -- The 'CommInfoReply' provides a list of currently open @comm@s with their
                 -- respective target names to the frontend.
                  CommInfoReply (Map UUID TargetName)
                 |
                 -- | The client sends a shutdown request to the kernel, and once it receives the
                 -- reply message (which is otherwise empty), it can assume that the kernel has
                 -- completed shutdown safely.
                 --
                 -- The 'ShutdownReply' allows for a safe shutdown, but, if no 'ShutdownReply' is
                 -- received (for example, if the kernel is deadlocked) client applications will
                 -- typically execute a last minute sanity check and forcefully terminate any
                 -- kernel that is still alive, to avoid leaving stray processes in the user’s
                 -- machine.
                  ShutdownReply Restart
  deriving (Eq, Ord, Show)

instance IsMessage KernelReply where
  getMessageType reply =
    case reply of
      KernelInfoReply{} -> "kernel_info_reply"
      ExecuteReply{}    -> "execute_reply"
      InspectReply{}    -> "inspect_reply"
      HistoryReply{}    -> "history_reply"
      CompleteReply{}   -> "complete_reply"
      IsCompleteReply{} -> "is_complete_reply"
      ConnectReply{}    -> "connect_reply"
      CommInfoReply{}   -> "comm_info_reply"
      ShutdownReply{}   -> "shutdown_reply"

instance ToJSON KernelReply where
  toJSON reply =
    object $
      case reply of
        KernelInfoReply KernelInfo { .. } ->
          [ "protocol_version" .= intercalate "." (map show kernelProtocolVersion)
          , "implementation" .= kernelImplementation
          , "implementation_version" .= kernelImplementationVersion
          , "banner" .= kernelBanner
          , "help_links" .= kernelHelpLinks
          , "language_info" .= kernelLanguageInfo
          ]
        ExecuteReply (ExecuteResult res) executionCount ->
          ("execution_count" .= executionCount) : formatResult res (const [])
        CompleteReply (CompleteResult res) ->
          formatResult res $ \(matches, range, metadata) ->
            [ "matches" .= matches
            , "cursor_start" .= cursorStart range
            , "cursor_end" .= cursorEnd range
            , "metadata" .= metadata
            ]
        InspectReply (InspectResult res) ->
          formatResult res $ \mDisplayData ->
            case mDisplayData of
              Nothing -> ("found" .= False) : mimebundleFields (DisplayData mempty)
              Just displayData -> ("found" .= True) : mimebundleFields displayData
        HistoryReply historyItems -> ["history" .= historyItems]
        IsCompleteReply codeComplete ->
          case codeComplete of
            CodeComplete          -> ["status" .= ("complete" :: Text)]
            CodeIncomplete indent -> ["status" .= ("incomplete" :: Text), "indent" .= indent]
            CodeInvalid           -> ["status" .= ("invalid" :: Text)]
            CodeUnknown           -> ["status" .= ("unknown" :: Text)]
        ConnectReply ConnectInfo { .. } ->
          [ "shell_port" .= connectShellPort
          , "iopub_port" .= connectIopubPort
          , "stdin_port" .= connectStdinPort
          , "hb_port" .= connectHeartbeatPort
          ]
        CommInfoReply targetNames ->
          let mkTargetNameDict (TargetName name) = object ["target_name" .= name]
          in ["comms" .= Map.mapKeys uuidToString (Map.map mkTargetNameDict targetNames)]
        ShutdownReply restart -> ["restart" .= restart]
    where
      formatResult :: OperationResult f -> (f -> [(Text, Value)]) -> [(Text, Value)]
      formatResult res mkFields =
        case res of
          OperationError err ->
            [ "status" .= ("error" :: Text)
            , "ename" .= errorName err
            , "evalue" .= errorValue err
            , "traceback" .= errorTraceback err
            ]
          OperationAbort ->
            ["status" .= ("abort" :: Text)]
          OperationOk f ->
            ("status" .= ("ok" :: Text)) : mkFields f

-- | Connection information about the ZeroMQ sockets the kernel communicates on.
data ConnectInfo =
       ConnectInfo
         { connectShellPort :: Int -- ^ The port the shell ROUTER socket is listening on.
         , connectIopubPort :: Int -- ^ The port the PUB socket is listening on.
         , connectStdinPort :: Int -- ^ The port the stdin ROUTER socket is listening on.
         , connectHeartbeatPort :: Int -- ^ The port the heartbeat socket is listening on.
         }
  deriving (Eq, Ord, Show)

-- | A completion match, including all the text (not just the text after the cursor).
newtype CompletionMatch = CompletionMatch Text
  deriving (Eq, Ord, Show, ToJSON)

-- | Range (of an input cell) to replace with a completion match.
data CursorRange =
       CursorRange
         { cursorStart :: Int  -- ^ Beginning of the range (in characters).
         , cursorEnd :: Int    -- ^ End of the range (in characters).
         }
  deriving (Eq, Ord, Show)


-- | One item from the kernel history, representing one single input to the kernel. An input
-- corresponds to a cell in a notebook, not a single line in a cell.
data HistoryItem =
       HistoryItem
         { historyItemSession :: Int         -- ^ The session of this input.
         , historyItemLine :: Int            -- ^ The line number in the session.
         , historyItemInput :: Text          -- ^ The input on this line.
         , historyItemOutput :: Maybe Text   -- ^ Optionally, the output when this was run.
         }
  deriving (Eq, Ord, Show)

instance ToJSON HistoryItem where
  toJSON HistoryItem { .. } =
    case historyItemOutput of
      Nothing     -> toJSON (historyItemSession, historyItemLine, historyItemInput)
      Just output -> toJSON (historyItemSession, historyItemLine, historyItemInput, output)

-- | Whether a string of code is complete (no more code needs to be entered), incomplete, or unknown
-- in status.
--
-- For example, when the user enters a line in a console style interface, the console must decide
-- whether to immediately execute the current code, or whether to show a continuation prompt for
-- further input. For instance, in Python @a = 5@ would be executed immediately, while @for i in
-- range(5):@ would expect further input.
data CodeComplete =
                  -- | The provided code is complete. Complete code is ready to be executed.
                   CodeComplete
                  |
                  -- | The provided code is incomplete, and the next line should be "indented" with
                  -- the provided text. Incomplete code should prompt for another line.
                   CodeIncomplete Text
                  |
                  -- | The provided code is invalid. Invalid code will typically be sent for
                  -- execution, so that the user sees the error soonest.
                   CodeInvalid
                  |
                  -- | Whether provided code is complete or not could not be determined. If the
                  -- code completeness is unknown, or the kernel does not reply in time, the
                  -- frontend may default to sending the code for execution, or use a simple
                  -- heuristic (execute after a blank line) .
                   CodeUnknown
  deriving (Eq, Ord, Show)

-- | The execution count, represented as an integer (number of cells evaluated up to this point).
newtype ExecutionCount = ExecutionCount Int
  deriving (Eq, Ord, Show, Num, ToJSON)

-- | All operations share a similar result structure. They can:
--   * complete successfully and return a result ('OperationOk')
--   * fail with an error ('OperationError')
--   * be aborted by the user ('OperationAbort')
--
-- This data type captures this pattern, and is used in a variety of replies, such as
-- 'ExecuteResult' and 'InspectResult.'
data OperationResult f =
                       -- | The operation completed successfully, returning some value @f@.
                        OperationOk f
                       |
                       -- | The operation failed, returning error information about the failure.
                        OperationError ErrorInfo
                       |
                       -- | The operation was aborted by the user.
                        OperationAbort
  deriving (Eq, Ord, Show)

-- | Result from an 'ExecuteRequest'.
--
-- No data is included with the result, because all execution results are published via
-- 'KernelOutput's instead.
newtype ExecuteResult = ExecuteResult (OperationResult ())
  deriving (Eq, Ord, Show)

-- | Shorthand pattern for a successful 'ExecuteResult'.
pattern ExecuteOk = ExecuteResult (OperationOk ())
--
-- | Shorthand pattern for an errored 'ExecuteResult'.
pattern ExecuteError info = ExecuteResult (OperationError info)
--
-- | Shorthand pattern for an aborted 'ExecuteResult'.
pattern ExecuteAbort = ExecuteResult OperationAbort

-- | Result from an 'InspectRequest'.
--
-- Result includes inspection results to show to the user (in rich 'DisplayData' format), or
-- 'Nothing' if no object was found.
newtype InspectResult = InspectResult (OperationResult (Maybe DisplayData))
  deriving (Eq, Ord, Show)

-- | Shorthand pattern for a successful 'ExecuteResult'.
pattern InspectOk disp = InspectResult (OperationOk disp)
--
-- | Shorthand pattern for an errored 'InspectResult'.
pattern InspectError info = InspectResult (OperationError info)
--
-- | Shorthand pattern for an aborted 'InspectResult'.
pattern InspectAbort = InspectResult OperationAbort

-- | Result from a 'CompleteRequest'.
--
-- Result includes a (possibly empty) list of matches, the range of characters to replace with the
-- matches, and any associated metadata for the completions.
newtype CompleteResult = CompleteResult (OperationResult ([CompletionMatch], CursorRange, Map Text Text))
  deriving (Eq, Ord, Show)

-- | Shorthand pattern for a successful 'ExecuteResult'.
pattern CompleteOk matches range meta = CompleteResult (OperationOk (matches, range, meta))
--
-- | Shorthand pattern for an errored 'CompleteResult'.
pattern CompleteError info = CompleteResult (OperationError info)
--
-- | Shorthand pattern for an aborted 'CompleteResult'.
pattern CompleteAbort = CompleteResult OperationAbort

-- | Error information, to be displayed to the user.
data ErrorInfo =
       ErrorInfo
         { errorName :: Text  -- ^ Name of the error or exception.
         , errorValue :: Text -- ^ Any values associated with the error or exception.
         , errorTraceback :: [Text] -- ^ If possible, a traceback for the error or exception.
         }
  deriving (Eq, Ord, Show)

-- | Reply content for a 'KernelInfoReply', containing core information about the kernel and the
-- kernel implementation. Pieces of this information are used throughout the frontend for display
-- purposes.
--
-- Refer to the lists of available <http://pygments.org/docs/lexers/ Pygments lexers> and <http://codemirror.net/mode/index.html Codemirror modes> for those fields.
data KernelInfo =
       KernelInfo
         { kernelProtocolVersion :: [Int]
         -- ^ Version of messaging protocol, usually two or three integers in the format @X.Y@ or @X.Y.Z@.
         -- The first integer indicates major version. It is incremented when there is any backward
         -- incompatible change. The second integer indicates minor version. It is incremented when there is
         -- any backward compatible change.
         , kernelBanner :: Text -- ^ A banner of information about the kernel, which may be desplayed
                                -- in console environments.
         , kernelImplementation :: Text -- ^ The kernel implementation name (e.g. @ipython@ for the
                                        -- IPython kernel)
         , kernelImplementationVersion :: Text -- ^ Implementation version number. The version number
                                               -- of the kernel's implementation (e.g.
                                               -- @IPython.__version__@ for the IPython kernel)
         , kernelLanguageInfo :: LanguageInfo -- ^ Information about the language of code for the
                                              -- kernel
         , kernelHelpLinks :: [HelpLink] -- ^ A list of help links. These will be displayed in the
                                         -- help menu in the notebook UI.
         }
  deriving (Eq, Ord, Show)

-- | Information about the language of code for a kernel.
data LanguageInfo =
       LanguageInfo
         { languageName :: Text      -- ^ Name of the programming language that the kernel implements.
                                     -- Kernel included in IPython returns 'python'.
         , languageVersion :: Text   -- ^ Language version number. It is Python version number (e.g.,
                                     -- '2.7.3') for the kernel included in IPython.
         , languageMimetype :: Text  -- ^ mimetype for script files in this language.
         , languageFileExtension :: Text  -- ^ Extension for script files including the dot, e.g.
                                          -- '.py'
         , languagePygmentsLexer :: Maybe Text -- ^ Pygments lexer, for highlighting (Only needed if
                                               -- it differs from the 'name' field.)
         , languageCodeMirrorMode :: Maybe Text -- ^ Codemirror mode, for for highlighting in the
                                                -- notebook. (Only needed if it differs from the
                                                -- 'name' field.)
         , languageNbconvertExporter :: Maybe Text -- ^ Nbconvert exporter, if notebooks written with
                                                   -- this kernel should be exported with something
                                                   -- other than the general 'script' exporter.
         }
  deriving (Eq, Ord, Show)

instance ToJSON LanguageInfo where
  toJSON LanguageInfo { .. } = object $
    concat
      [ [ "name" .= languageName
        , "version" .= languageVersion
        , "mimetype" .= languageMimetype
        , "file_extension" .= languageFileExtension
        ]
      , maybe [] (\v -> ["pygments_lexer" .= v]) languagePygmentsLexer
      , maybe [] (\v -> ["codemirror_mode" .= v]) languageCodeMirrorMode
      , maybe [] (\v -> ["nbconvert_exporter" .= v]) languageNbconvertExporter
      ]

-- | A link to some help text to include in the frontend's help menu.
data HelpLink =
       HelpLink
         { helpLinkText :: Text -- ^ Text to show for the link.
         , helpLinkURL :: Text  -- ^ URL the link points to.
                                --
                                -- This URL is not validated, and is used directly as the link
                                -- destination.
         }
  deriving (Eq, Ord, Show)

instance ToJSON HelpLink where
  toJSON HelpLink { .. } =
    object ["text" .= helpLinkText, "url" .= helpLinkURL]

-- | Although usually kernels respond to clients' requests, the request/reply can also go in the
-- opposite direction: from the kernel to a single frontend. The purpose of these messages (sent on
-- the /stdin/ socket) is to allow code to request input from the user (in particular reading from
-- standard input) and to have those requests fulfilled by the client. The request should be made to
-- the frontend that made the execution request that prompted the need for user input.
data KernelRequest =
     -- | Request text input from standard input.
      InputRequest InputOptions
  deriving (Eq, Ord, Show)

-- | Metadata for requesting input from the user.
data InputOptions =
       InputOptions
         { inputPrompt :: Text  -- ^ Prompt for the user.
         , inputPassword :: Bool -- ^ Is this prompt entering a password? On some frontends this will
                                 -- cause
         }
  -- the characters to be hidden during entry. 
  deriving (Eq, Ord, Show)

-- | Replies from the client to the kernel, as a result of the kernel sending a 'KernelRequest' to
-- the client.
data ClientReply =
     -- | Returns the text input by the user to the frontend.
      InputReply Text
  deriving (Eq, Ord, Show)

-- | During processing and code execution, the kernel publishes side effects through messages sent
-- on its /iopub/ socket. Side effects include kernel outputs and notifications, such as writing to
-- standard output or standard error, displaying rich outputs via @display_data@ messages, updating
-- the frontend with kernel status, etc.
--
-- Multiple frontends may be subscribed to a single kernel, and 'KernelOutput' messages are
-- published to all frontends simultaneously.
data KernelOutput =
                  -- | Write text to @stdout@ or @stderr@.
                   StreamOutput Stream Text
                  |
                  -- | Send data that should be displayed (text, html, svg, etc.) to all frontends.
                  -- Each message can have multiple representations of the data; it is up to the
                  -- frontend to decide which to use and how. A single message should contain all
                  -- possible representations of the same information; these representations are
                  -- encapsulated in the 'DisplayData' type.
                   DisplayDataOutput DisplayData
                  |
                  -- | Inform all frontends of the currently executing code. To let all frontends
                  -- know what code is being executed at any given time, these messages contain a
                  -- re-broadcast of the code portion of an 'ExecuteRequest', along with the
                  -- 'ExecutionCount'.
                   ExecuteInputOutput CodeBlock ExecutionCount
                  |
                  -- | Results of an execution are published as an 'ExecuteResult'. These are
                  -- identical to @display_data@ ('DisplayDataOutput') messages, with the addition
                  -- of an 'ExecutionCount' key.
                  --
                  -- Results can have multiple simultaneous formats depending on its configuration.
                  -- A plain text representation should always be provided in the text/plain
                  -- mime-type ('MimePlainText'). Frontends are free to display any or all of the
                  -- provided representations according to their capabilities, and should ignore
                  -- mime-types they do not understand. The data itself is any JSON object and
                  -- depends on the format. It is often, but not always a string.
                   ExecuteResultOutput ExecutionCount DisplayData
                  |
                  -- | When an error occurs during code execution, a 'ExecuteErrorOutput' should be
                  -- published to inform all frontends of the error.
                   ExecuteErrorOutput ErrorInfo
                  |
                  -- | Inform the frontends of the current kernel status. This lets frontends
                  -- display usage stats and loading indicators to the user.
                  --
                  -- This message type is used by frontends to monitor the status of the kernel.
                  --
                  -- Note: 'KernelBusy' and 'KernelIdle' messages should be sent before and after
                  -- handling /every/ message, not just code execution.
                   KernelStatusOutput KernelStatus
                  |
                  -- | This message type is used to clear the output that is visible on the
                  -- frontend.
                  --
                  -- The 'WaitBeforeClear' parameter changes when the output will be cleared
                  -- (immediately or delayed until next output).
                   ClearOutput WaitBeforeClear
  deriving (Eq, Ord, Show)

instance IsMessage KernelOutput where
  getMessageType msg =
    case msg of
      StreamOutput{}        -> "stream"
      DisplayDataOutput{}   -> "display_data"
      ExecuteInputOutput{}  -> "execute_input"
      ExecuteResultOutput{} -> "execute_result"
      ExecuteErrorOutput{}  -> "error"
      KernelStatusOutput{}  -> "status"
      ClearOutput{}         -> "clear_output"

instance ToJSON KernelOutput where
  toJSON output =
    object $
      case output of
        StreamOutput stream text ->
          ["name" .= stream, "text" .= text]
        DisplayDataOutput displayData -> mimebundleFields displayData
        ExecuteInputOutput code executionCount ->
          ["code" .= code, "execution_count" .= executionCount]
        ExecuteResultOutput executionCount displayData ->
          ("execution_count" .= executionCount) : mimebundleFields displayData
        ExecuteErrorOutput err ->
          ["ename" .= errorName err, "evalue" .= errorValue err, "traceback" .= errorTraceback err]
        KernelStatusOutput status ->
          ["execution_state" .= status]
        ClearOutput wait ->
          ["wait" .= wait]

-- | Output stream to write messages to.
data Stream = StreamStdout -- ^ @stdout@
            | StreamStderr -- ^ @stderr@
  deriving (Eq, Ord, Show)

instance ToJSON Stream where
  toJSON StreamStdout = "stdout"
  toJSON StreamStderr = "stderr"

-- | Whether a 'ClearOutput' should clear the display immediately, or clear the display right before
-- the next display arrives.
--
-- If 'ClearImmediately' is used, then the frontend may "blink", as there may be a moment after the
-- display is cleared but before a new display available, whereas 'ClearBeforeNextOutput' is meant
-- to alleviate the blinking effect.
--
-- Used with the 'ClearOutput' kernel output message.
data WaitBeforeClear = ClearBeforeNextOutput -- ^ Clear the display area immediately.
                     | ClearImmediately      -- ^ Clear the display area right before the next display
                                             -- arrives.
  deriving (Eq, Ord, Show)

instance ToJSON WaitBeforeClear where
  toJSON ClearBeforeNextOutput = Bool True
  toJSON ClearImmediately = Bool False

-- | Status of the kernel.
--
-- Used with 'KernelStatusOutput' messages to let the frontend know what the kernel is doing.
data KernelStatus = KernelIdle     -- ^ @idle@: The kernel is available for more processing tasks.
                  | KernelBusy     -- ^ @busy@: The kernel is currently processing and busy.
                  | KernelStarting -- ^ @starting@: The kernel is loading and is not yet available
                                   -- for processing.
  deriving (Eq, Ord, Show)

instance ToJSON KernelStatus where
  toJSON KernelIdle = "idle"
  toJSON KernelBusy = "busy"
  toJSON KernelStarting = "starting"

-- | Target module for a @comm_open@ message, optionally used in combination with a 'TargetName' to 
-- let the receiving side of the 'CommOpen' message know how to create the @comm@.
newtype TargetModule = TargetModule Text
  deriving (Eq, Ord, Show, FromJSON, ToJSON)

-- | 'Comm' messages provide developers with an unstructured communication channel between the
-- kernel and the frontend which exists on both sides and can communicate in any direction.
--
-- These messages are fully symmetrical - both the kernel and the frontend can send each message,
-- and no messages expect a reply.
--
-- Every @comm@ has an ID and a target name. The code handling the message on the receiving side
-- (which may be the client or the kernel) is responsible for creating a @comm@ given the target
-- name of the @comm@ being created.
--
-- Once a @comm@ is open with a 'CommOpen' message, the @comm@ should exist immediately on both
-- sides, until the comm is closed with a 'CommClose' message.
--
-- For more information on @comm@ messages, read the
-- <https://jupyter-client.readthedocs.io/en/latest/messaging.html#custom-messages section in the Jupyter messaging spec>.
data Comm =
          -- | A @comm_open@ message used to request that the receiving end create a @comm@ with
          -- the provided UUID and target name.
          --
          -- The 'TargetName' lets the receiving end what sort of @comm@ to create; this
          -- can also be refined with an optional 'TargetModule', which can select the
          -- module responsible for creating this @comm@ (for languages or environments in
          -- which the idea of a module is meaningful). Although such a distinction is not
          -- always meaningful, the 'TargetModule' is often used to select a module (such
          -- as a Python module) and the 'TargetName' is often used to select the
          -- constructor or function in that module that then creates the @comm@.
          --
          -- The auxiliary JSON @data@ value can contain any information the client or kernel
          -- wishes to include for this @comm@ message.
           CommOpen UUID Value TargetName (Maybe TargetModule)
          |
          -- | A @comm_close@ message destroys a @comm@, selecting it by its UUID.
          --
          -- The auxiliary JSON @data@ value can contain any information the client or kernel
          -- wishes to include for this @comm@ message.
           CommClose UUID Value
          |
          -- | A @comm_msg@ message sends some JSON data to a @comm@, selecting it by its UUID.
           CommMessage UUID Value
  deriving (Eq, Show)

instance IsMessage Comm where
  getMessageType comm =
    case comm of
      CommOpen{}    -> "comm_open"
      CommClose{}   -> "comm_close"
      CommMessage{} -> "comm_msg"

instance ToJSON Comm where
  toJSON comm =
    object $
      case comm of
        CommOpen uuid commData targetName mTargetModule ->
          ["comm_id" .= uuid, "data" .= commData, "target_name" .= targetName] ++
          maybe [] (\targetModule -> ["target_module" .= targetModule]) mTargetModule
        CommClose uuid commData ->
          ["comm_id" .= uuid, "data" .= commData]
        CommMessage uuid commData ->
          ["comm_id" .= uuid, "data" .= commData]

-- | A @display_data@ /mimebundle/ used to publish rich data to Jupyter frontends.
--
-- A mimebundle contains all possible representations of an object available to the kernel in a map
-- from 'MimeType' keys to encoded data values. By sending all representations to the Jupyter
-- frontends, kernels allow the frontends to select the most appropriate representation; for
-- instance, the console frontend may prefer to use a text representation, while the notebook will
-- prefer to use an HTML or PNG representation.
--
-- All data must be encoded into 'Text' values; for items such as images, the data must be
-- base64-encoded prior to transmission.
newtype DisplayData = DisplayData (Map MimeType Text)
  deriving (Eq, Ord, Show, Typeable, Generic)

-- | Convert a 'DisplayData' to a list of JSON fields.
--
-- This is effectively equivalent to a 'ToJSON' instance, but since 'DisplayData' fields are in
-- several messages integrated into the message fields, we provide this conversion instead.
mimebundleFields :: DisplayData -> [(Text, Value)]
mimebundleFields (DisplayData displayData) =
  ["data" .= encodeDisplayData displayData, "metadata" .= encodeDisplayMetadata displayData]
  where
    encodeDisplayData = Map.mapKeys showMimeType
    encodeDisplayMetadata =
      Map.mapKeys showMimeType . Map.mapMaybeWithKey (\mime _ -> mimeTypeMetadata mime)


-- | Dimensions of an image, to be included with the 'DisplayData' bundle in the 'MimeType'.
data ImageDimensions =
       ImageDimensions
         { imageWidth :: Int  -- ^ Image width, in pixels.
         , imageHeight :: Int -- ^ Image height, in pixels.
         }
  deriving (Eq, Ord, Show)

instance ToJSON ImageDimensions where
  toJSON (ImageDimensions width height) = object ["width" .= width, "height" .= height]

-- | Mime types for the display data, with any associated metadata that the mime types may require.
data MimeType = MimePlainText -- ^ @text/plain@
              | MimeHtml      -- ^ @text/html@
              | MimePng ImageDimensions -- ^ @image/png@, with associated image width and height
              | MimeJpg ImageDimensions -- ^ @image/jpg@, with associated image width and height
              | MimeSvg -- ^ @image/svg+xml@
              | MimeLatex -- ^ @text/latex@
              | MimeJavascript -- ^ @application/javascript@
  deriving (Eq, Ord, Show, Typeable, Generic)

-- | Convert a 'MimeType' into its standard string representation.
--
-- >>> showMimeType MimePlainText
-- "text/plain"
--
-- >>> showMimeType MimeJavascript
-- "application/javascript"
--
-- >>> showMimeType (MimePng (ImageDimensions 100 200))
-- "image/png"
showMimeType :: MimeType -> Text
showMimeType mime =
  case mime of
    MimePlainText  -> "text/plain"
    MimeHtml       -> "text/html"
    MimePng _      -> "image/png"
    MimeJpg _      -> "image/jpeg"
    MimeSvg        -> "image/svg+xml"
    MimeLatex      -> "text/latex"
    MimeJavascript -> "application/javascript"

-- | Extract any metadata associated with this 'MimeType' value.
--
-- Metadata is included with @display_data@ ('DisplayData') messages to give more information to the
-- frontends about how to display the resource. Most mime types lack any metadata, but not all; in
-- particular some image types may have image dimensions.
--
-- >>> mimeTypeMetadata MimeHtml
-- Nothing
--
-- >>> mimeTypeMetadata (MimePng (ImageDimensions 100 200))
-- Object (fromList [("width", Number 100.0), ("height", Number 200.0)])
mimeTypeMetadata :: MimeType -> Maybe Value
mimeTypeMetadata mime =
  case mime of
    MimePng dims -> Just $ toJSON dims
    MimeJpg dims -> Just $ toJSON dims
    _            -> Nothing
