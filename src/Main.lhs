> {-# LANGUAGE OverloadedStrings #-}
> {-# LANGUAGE UnicodeSyntax #-}
> module Main where




Imports
--------------------------------------------------------------------------------

> import Network.Connection
> import System.IO
> import System.Timeout
> import System.ZMQ4.Monadic
> import Control.Applicative
> import Control.Monad
> import Control.Concurrent
> import Control.Concurrent.MVar
> import Text.Printf
> import Text.Regex.PCRE
> import Data.Aeson
> import Data.List (intersperse)
> import Data.List.Split

Qualified imports to prevent namespace clashes.

> import qualified Data.ByteString.Char8 as C8
> import qualified Data.ByteString.Lazy.Char8 as C8Lazy

Imports from within the current code base.

> import Config
> import qualified IRC




Routing Thread
--------------------------------------------------------------------------------
A routing thread exists to simply take messages and broadcast them through
Pub/Sub. This is essentially a small tag based message broker that plugins
can use to communicate.

> route ∷ IO ()
> route = runZMQ $ do

Two sockets are required, one as a sink that other plugins can push their
messages to, and the other the publisher for broadcasting.

>     pub  ← socket Pub
>     sink ← socket Pull
>     bind pub  "tcp://0.0.0.0:9890"
>     bind sink "tcp://0.0.0.0:9891"

With these two sockets, we simply setup a piping operation that reads and
forwards forever.

>     forever $ do
>         msg ← receive sink
>         send pub [] msg




Plugin Thread
--------------------------------------------------------------------------------
This thread is a plugin, it could be written in another language and in another
process, but it is the main goal of this project so it is written here and ran
as a seperate thread. The job of this plugin is to be a bridge between plugins
and IRC networks.

We need a parsing function for parsing routed messages so that we can parse IPC
calls to this plugin.

> data Message = Message {
>     msgTag  ∷ String,
>     msgFrom ∷ String,
>     msgTo   ∷ String,
>     msgArgs ∷ [String],
>     msgPay  ∷ String
>     }
>     deriving (Show)

> parse ∷ String → Message
> parse s = Message {
>     msgTag  = parts !! 0,
>     msgFrom = from,
>     msgTo   = to,
>     msgArgs = args,
>     msgPay  = payload
>     }
>     where
>         parts     = splitOn " " s
>         [from,to] = splitOn "!" (parts !! 1)
>         count     = read (parts !! 2)
>         args      = (take count . drop 2) parts
>         payload   = last parts

Also need a function that does the reverse, and packs messages into routing
format for sending.

> pack ∷ Message -> String
> pack s = printf "%s %s!%s %d %s %s" a0 a1 a2 a3 a4 a5
>     where
>         a0 = msgTag s
>         a1 = msgFrom s
>         a2 = msgTo s
>         a3 = length (msgArgs s)
>         a4 = (concat . intersperse " ") (msgArgs s)
>         a5 = msgPay s




Now we can use these in the main plugin thread itself.

> bridge ∷ Either String Config → IO ()
> bridge (Left err)   = putStrLn ("Error Parsing: " ++ err)
> bridge (Right conf) = do

A set of networks is needed to start with. Connecting to these networks is done
in a seperate module.

>     networks ← mapM IRC.connect (servers conf)

The rest we do in a ZMQ context, this is so that we can share the context among
all the threads that are about to be spawned.

>     runZMQ $ do
>         flip mapM_ networks $ \(name, network) →

Spawn a thread for each network, pushing messages out from each network into
the push queue for the route thread to broadcast.

>             async $ do
>                 push ← socket Push
>                 connect push "tcp://0.0.0.0:9891"
>                 forever $ do
>                     message ← liftIO (connectionGetLine 128 network)
>                     let irc = IRC.parse (C8.unpack message)
>                         pay = (IRC.format . C8.unpack) message
>                         msg = Message ("IRC:" ++ (irc !! 1)) "core" "*" [] pay
>
>                     send push [] (C8.pack . pack $ msg)

We now also subscribe to the publisher, we are a plugin and we care about all
messages other plugins want us to forward back out. We do this by listening to
IPC calls that ask us to forward.

>         sub ← socket Sub
>         connect sub "tcp://0.0.0.0:9890"
>         subscribe sub ""

Loop forever, parsing IPC calls and forwarding messages out into IRC networks
when they are received.

>         forever $ do
>             line ← receive sub
>             let parsed = parse (C8.unpack line)
>             liftIO(putStrLn $ show parsed)




> main ∷ IO ()
> main = forkIO route >> readFile "config" >>= bridge . eitherDecode . C8Lazy.pack



ircLoop ∷ Either String Config → IO ()
ircLoop (Left err)   = putStrLn err
ircLoop (Right conf) = do
    {- Run the routing thread. This thread, conceptually, is another process
     - and is the core of the router. All plugins, including this process which
     - is technically a plugin use the router thread for communication. -}
    forkIO route
        -- Lets Go
        forever $ do
            line <- receive sub
            let unpacked    = C8.unpack line
                tag         = takeWhile ('('/=) unpacked
                payload     = tail . dropWhile (')'/=) $ unpacked
                argsplits   = tail . dropWhile (','/=) $ unpacked
                destination = takeWhile (')'/=) $ argsplits
                target      = lookup destination networks

            -- Handle different WAR commands.
            case tag of
                {- Forwards messages out into the relevant IRC networks. -}
                "WAR:FORWARD" ->
                    case target of
                        Just s  -> liftIO (connectionPut s . ircPack $ payload)
                        Nothing -> return ()

                {- Broadcasts messages on the publisher. -}
                "WAR:BROADCAST" ->
                    send req [] (C8.pack payload)

                {- Reply to INFO requests. -}
                "WAR:INFO" ->
                    return ()

                {- Unknown Command. Do nothing. -}
                _ ->
                    return ()



{- Main thread. This handles the actual heavy lifting of dealing with IRC
 - networking and config parsing. -}
main :: IO ()
main = readFile "config" >>= ircLoop . eitherDecode . C8Lazy.pack
