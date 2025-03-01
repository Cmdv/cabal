{-# LANGUAGE CPP                      #-}
{-# LANGUAGE NondecreasingIndentation #-}
{-# LANGUAGE PatternGuards            #-}
{-# LANGUAGE ScopedTypeVariables      #-}

import Test.Cabal.Workdir
import Test.Cabal.Script
import Test.Cabal.Server
import Test.Cabal.Monad
import Test.Cabal.TestCode

import Distribution.Verbosity        (normal, verbose, Verbosity)
import Distribution.Simple.Utils     (getDirectoryContentsRecursive)

import Options.Applicative
import Control.Concurrent.MVar
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad
import GHC.Conc (numCapabilities)
import Data.List
import Text.Printf
import qualified System.Clock as Clock
import System.IO
import System.FilePath
import System.Exit
import System.Process (callProcess, showCommandForUser)

#if !MIN_VERSION_base(4,12,0)
import Data.Monoid ((<>))
#endif
#if !MIN_VERSION_base(4,8,0)
import Data.Monoid (mempty)
#endif

-- | Record for arguments that can be passed to @cabal-tests@ executable.
data MainArgs = MainArgs {
        mainArgThreads :: Int,
        mainArgTestPaths :: [String],
        mainArgHideSuccesses :: Bool,
        mainArgVerbose :: Bool,
        mainArgQuiet   :: Bool,
        mainArgDistDir :: Maybe FilePath,
        mainCommonArgs :: CommonArgs
    }

-- | optparse-applicative parser for 'MainArgs'
mainArgParser :: Parser MainArgs
mainArgParser = MainArgs
    <$> option auto
        ( help "Number of threads to run"
       <> short 'j'
       <> showDefault
       <> value numCapabilities
       <> metavar "INT")
    <*> many (argument str (metavar "FILE"))
    <*> switch
        ( long "hide-successes"
       <> help "Do not print test cases as they are being run"
        )
    <*> switch
        ( long "verbose"
       <> short 'v'
       <> help "Be verbose"
        )
    <*> switch
        ( long "quiet"
       <> short 'q'
       <> help "Only output stderr on failure"
        )
    <*> optional (option str
        ( help "Dist directory we were built with"
       <> long "builddir"
       <> metavar "DIR"))
    <*> commonArgParser

main :: IO ()
main = do
    -- By default, stderr is not buffered.  This isn't really necessary
    -- for us, and it causes problems on Windows, see:
    -- https://github.com/appveyor/ci/issues/1364
    hSetBuffering stderr LineBuffering

    -- Parse arguments
    args <- execParser (info mainArgParser mempty)
    let verbosity = if mainArgVerbose args then verbose else normal

    -- To run our test scripts, we need to be able to run Haskell code
    -- linked against the Cabal library under test.  The most efficient
    -- way to get this information is by querying the *host* build
    -- system about the information.
    --
    -- Fortunately, because we are using a Custom setup, our Setup
    -- script is bootstrapped against the Cabal library we're testing
    -- against, so can use our dependency on Cabal to read out the build
    -- info *for this package*.
    --
    -- NB: Currently assumes that per-component build is NOT turned on
    -- for Custom.
    dist_dir <- case mainArgDistDir args of
                  Just dist_dir -> return dist_dir
                  Nothing -> guessDistDir
    when (verbosity >= verbose) $
        hPutStrLn stderr $ "Using dist dir: " ++ dist_dir
    -- Get ready to go!
    senv <- mkScriptEnv verbosity

    let runTest :: (Maybe cwd -> [unusedEnv] -> FilePath -> [String] -> IO result)
                -> FilePath
                -> IO result
        runTest runner path
            = runner Nothing [] path $
                ["--builddir", dist_dir, path] ++ renderCommonArgs (mainCommonArgs args)

    case mainArgTestPaths args of
        [path] -> do
            -- Simple runner
            (real_path, real_args) <- runTest (runnerCommand senv) path
            hPutStrLn stderr $ showCommandForUser real_path real_args
            callProcess real_path real_args
            hPutStrLn stderr "OK"
        user_paths -> do
            -- Read out tests from filesystem
            hPutStrLn stderr $ "threads: " ++ show (mainArgThreads args)

            test_scripts <- if null user_paths
                                then findTests
                                else return user_paths
            -- NB: getDirectoryContentsRecursive is lazy IO, but it
            -- doesn't handle directories disappearing gracefully. Fix
            -- this!
            (single_tests, multi_tests) <- evaluate (partitionTests test_scripts)
            let all_tests = multi_tests ++ single_tests
                margin = maximum (map length all_tests) + 2
            hPutStrLn stderr $ "tests to run: " ++ show (length all_tests)

            -- TODO: Get parallelization out of multitests by querying
            -- them for their modes and then making a separate worker
            -- for each.  But for now, just run them earlier to avoid
            -- them straggling at the end
            work_queue <- newMVar all_tests
            unexpected_fails_var  <- newMVar []
            unexpected_passes_var <- newMVar []
            skipped_var <- newMVar []

            chan <- newChan
            let logAll msg = writeChan chan (ServerLogMsg AllServers msg)
                logEnd = writeChan chan ServerLogEnd
            -- NB: don't use withAsync as we do NOT want to cancel this
            -- on an exception
            async_logger <- async (withFile "cabal-tests.log" WriteMode $ outputThread verbosity chan)

            -- Make sure we pump out all the logs before quitting
            (\m -> finally m (logEnd >> wait async_logger)) $ do

            -- NB: Need to use withAsync so that if the main thread dies
            -- (due to ctrl-c) we tear down all of the worker threads.
            let go server = do
                    let split [] = return ([], Nothing)
                        split (y:ys) = return (ys, Just y)
                        logMeta msg = writeChan chan
                                    $ ServerLogMsg
                                        (ServerMeta (serverProcessId server))
                                        msg
                    mb_work <- modifyMVar work_queue split
                    case mb_work of
                        Nothing -> return ()
                        Just path -> do
                            when (verbosity >= verbose) $
                                logMeta $ "Running " ++ path
                            start <- getTime
                            r <- runTest (runOnServer server) path
                            end <- getTime
                            let time = end - start
                                code = serverResultTestCode r

                            unless (mainArgHideSuccesses args && code == TestCodeOk) $ do
                                logMeta $
                                    path ++ replicate (margin - length path) ' ' ++ displayTestCode code ++
                                    if time >= 0.01
                                        then printf " (%.2fs)" time
                                        else ""

                            when (code == TestCodeFail) $ do
                                let description
                                      | mainArgQuiet args = serverResultStderr r
                                      | otherwise =
                                       "$ " ++ serverResultCommand r ++ "\n" ++
                                       "stdout:\n" ++ serverResultStdout r ++ "\n" ++
                                       "stderr:\n" ++ serverResultStderr r ++ "\n"
                                logMeta $
                                          description
                                       ++ "*** unexpected failure for " ++ path ++ "\n\n"
                                modifyMVar_ unexpected_fails_var $ \paths ->
                                    return (path:paths)

                            when (code == TestCodeUnexpectedOk) $
                                modifyMVar_ unexpected_passes_var $ \paths ->
                                    return (path:paths)

                            when (isTestCodeSkip code) $
                                modifyMVar_ skipped_var $ \paths ->
                                    return (path:paths)

                            go server

            -- Start as many threads as requested by -j to spawn
            -- GHCi servers and start running tests off of the
            -- run queue.
            replicateConcurrently_ (mainArgThreads args) (withNewServer chan senv go)

            unexpected_fails  <- takeMVar unexpected_fails_var
            unexpected_passes <- takeMVar unexpected_passes_var
            skipped           <- takeMVar skipped_var

            -- print summary
            let sl = show . length
                testSummary =
                  sl all_tests ++ " tests, " ++ sl skipped ++ " skipped, "
                    ++ sl unexpected_passes ++ " unexpected passes, "
                    ++ sl unexpected_fails ++ " unexpected fails."
            logAll testSummary

            -- print failed or unexpected ok
            if null (unexpected_fails ++ unexpected_passes)
            then logAll "OK"
            else do
                unless (null unexpected_passes) . logAll $
                    "UNEXPECTED OK: " ++ intercalate " " unexpected_passes
                unless (null unexpected_fails) . logAll $
                    "UNEXPECTED FAIL: " ++ intercalate " " unexpected_fails
                exitFailure

findTests :: IO [FilePath]
findTests = getDirectoryContentsRecursive "."

partitionTests :: [FilePath] -> ([FilePath], [FilePath])
partitionTests = go [] []
  where
    go ts ms [] = (ts, ms)
    go ts ms (f:fs) =
        -- NB: Keep this synchronized with isTestFile
        case takeExtensions f of
            ".test.hs"      -> go (f:ts) ms fs
            ".multitest.hs" -> go ts (f:ms) fs
            _               -> go ts ms     fs

outputThread :: Verbosity -> Chan ServerLogMsg -> Handle -> IO ()
outputThread verbosity chan log_handle = go ""
  where
    go prev_hdr = do
        v <- readChan chan
        case v of
            ServerLogEnd -> return ()
            ServerLogMsg t msg -> do
                let ls = lines msg
                    pre s c
                        | verbosity >= verbose
                        -- Didn't use printf as GHC 7.4
                        -- doesn't understand % 7s.
                        = replicate (7 - length s) ' ' ++ s ++ " " ++ c : " "
                        | otherwise = ""
                    hdr = case t of
                            AllServers   -> ""
                            ServerMeta s -> pre s ' '
                            ServerIn   s -> pre s '<'
                            ServerOut  s -> pre s '>'
                            ServerErr  s -> pre s '!'
                    ws = replicate (length hdr) ' '
                    mb_hdr l | hdr == prev_hdr = ws ++ l
                             | otherwise = hdr ++ l
                    ls' = case ls of
                            [] -> []
                            r:rs ->
                                mb_hdr r : map (ws ++) rs
                    logmsg = unlines ls'
                hPutStr stderr logmsg
                hPutStr log_handle logmsg
                go hdr

-- Cribbed from tasty
type Time = Double

getTime :: IO Time
getTime = do
    t <- Clock.getTime Clock.Monotonic
    let ns = realToFrac $ Clock.toNanoSecs t
    return $ ns / 10 ^ (9 :: Int)
