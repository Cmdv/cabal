{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HackageBenchmark (
    hackageBenchmarkMain

-- Exposed for testing:
  , CabalResult(..)
  , isSignificantTimeDifference
  , combineTrialResults
  , isSignificantResult
  , shouldContinueAfterFirstTrial
  ) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (forM, replicateM, unless, when)
import qualified Data.ByteString as BS
import Data.List (nub, unzip4)
import Data.Maybe (isJust, catMaybes)
import Data.Monoid ((<>))
import Data.String (fromString)
import Data.Function ((&))
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
import qualified Data.Vector.Unboxed as V
import Options.Applicative
import Statistics.Sample (mean, stdDev, geometricMean)
import Statistics.Test.MannWhitneyU ( PositionTest(..), TestResult(..)
                                    , mannWhitneyUCriticalValue
                                    , mannWhitneyUtest)
import Statistics.Types (PValue, mkPValue)
import System.Directory (getTemporaryDirectory, createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode(..), exitWith, exitFailure)
import System.FilePath ((</>))
import System.IO ( BufferMode(LineBuffering), hPutStrLn, hSetBuffering, stderr
                 , stdout)
import System.Process ( StdStream(CreatePipe), CreateProcess(..), callProcess
                      , createProcess, readProcess, shell, waitForProcess, proc, readCreateProcessWithExitCode )
import Text.Printf (printf)

import qualified Data.Map.Strict as Map

import Distribution.Package (PackageName, mkPackageName, unPackageName)

data Args = Args {
    argCabal1                      :: FilePath
  , argCabal2                      :: FilePath
  , argCabal1Flags                 :: [String]
  , argCabal2Flags                 :: [String]
  , argPackages                    :: [PackageName]
  , argMinRunTimeDifferenceToRerun :: Double
  , argPValue                      :: PValue Double
  , argTrials                      :: Int
  , argConcurrently                :: Bool
  , argPrintTrials                 :: Bool
  , argPrintSkippedPackages        :: Bool
  , argTimeoutSeconds              :: Int
  }

data CabalTrial = CabalTrial NominalDiffTime CabalResult

data CabalResult
  = Solution
  | NoInstallPlan
  | BackjumpLimit
  | Unbuildable
  | UnbuildableDep
  | ComponentCycle
  | ModReexpIssue
  | PkgNotFound
  | Timeout
  | Unknown
  deriving (Eq, Show)

hackageBenchmarkMain :: IO ()
hackageBenchmarkMain = do
  hSetBuffering stdout LineBuffering
  args@Args {..} <- execParser parserInfo
  checkArgs args
  printConfig args
  pkgs <- getPackages args
  putStrLn ""

  let concurrently' :: IO a -> IO b -> IO (a, b)
      concurrently' | argConcurrently = concurrently
                    | otherwise       = \ma mb -> do { a <- ma; b <- mb; return (a, b) }

  let -- The maximum length of the heading and package names.
      nameColumnWidth :: Int
      nameColumnWidth =
          maximum $ map length $ "package" : map unPackageName pkgs

  -- create cabal runners
  runCabal1 <- runCabal argTimeoutSeconds CabalUnderTest1 argCabal1 argCabal1Flags
  runCabal2 <- runCabal argTimeoutSeconds CabalUnderTest2 argCabal2 argCabal2Flags

  -- When the output contains both trails and summaries, label each row as
  -- "trial" or "summary".
  when argPrintTrials $ putStr $ printf "%-16s " "trial/summary"
  putStrLn $
      printf "%-*s %-14s %-14s %11s %11s %11s %11s %11s"
             nameColumnWidth "package" "result1" "result2"
             "mean1" "mean2" "stddev1" "stddev2" "speedup"

  speedups :: [Double] <- fmap catMaybes $ forM pkgs $ \pkg -> do
    let printTrial msgType result1 result2 time1 time2 =
            putStrLn $
            printf "%-16s %-*s %-14s %-14s %10.3fs %10.3fs"
                   msgType nameColumnWidth (unPackageName pkg)
                   (show result1) (show result2)
                   (diffTimeToDouble time1) (diffTimeToDouble time2)

    (CabalTrial t1 r1, CabalTrial t2 r2) <- runCabal1 pkg `concurrently'` runCabal2 pkg

    if not $
       shouldContinueAfterFirstTrial argMinRunTimeDifferenceToRerun t1 t2 r1 r2
    then do
      when argPrintSkippedPackages $
         if argPrintTrials
         then printTrial "trial (skipping)" r1 r2 t1 t2
         else putStrLn $ printf "%-*s (first run times were too similar)"
                                nameColumnWidth (unPackageName pkg)
      return Nothing
    else do
      when argPrintTrials $ printTrial "trial" r1 r2 t1 t2
      (ts1, ts2, rs1, rs2) <- (unzip4 . ((t1, t2, r1, r2) :) <$>)
                            . replicateM (argTrials - 1) $ do

        (CabalTrial t1' r1', CabalTrial t2' r2') <- runCabal1 pkg `concurrently'` runCabal2 pkg
        when argPrintTrials $ printTrial "trial" r1' r2' t1' t2'
        return (t1', t2', r1', r2')

      let result1 = combineTrialResults rs1
          result2 = combineTrialResults rs2
          times1 = V.fromList (map diffTimeToDouble ts1)
          times2 = V.fromList (map diffTimeToDouble ts2)
          mean1 = mean times1
          mean2 = mean times2
          stddev1 = stdDev times1
          stddev2 = stdDev times2
          speedup = mean1 / mean2

      when argPrintTrials $ putStr $ printf "%-16s " "summary"
      if isSignificantResult result1 result2
          || isSignificantTimeDifference argPValue ts1 ts2
      then putStrLn $
           printf "%-*s %-14s %-14s %10.3fs %10.3fs %10.3fs %10.3fs %10.3f"
                  nameColumnWidth (unPackageName pkg)
                  (show result1) (show result2) mean1 mean2 stddev1 stddev2 speedup
      else when (argPrintTrials || argPrintSkippedPackages) $
           putStrLn $
           printf "%-*s (not significant, speedup = %10.3f)" nameColumnWidth (unPackageName pkg) speedup

      -- return speedup value
      return (Just speedup)

  -- finally, calculate the geometric mean of speedups
  printf "Geometric mean of %d packages' speedups is %10.3f\n" (length speedups) (geometricMean (V.fromList speedups))

  where
    checkArgs :: Args -> IO ()
    checkArgs Args {..} = do
      let die msg = hPutStrLn stderr msg >> exitFailure
      unless (argTrials > 0) $ die "--trials must be greater than 0."
      unless (argMinRunTimeDifferenceToRerun >= 0) $
          die "--min-run-time-percentage-difference-to-rerun must be non-negative."
      unless (isSampleLargeEnough argPValue argTrials) $
          die "p-value is too small for the number of trials."

    printConfig :: Args -> IO ()
    printConfig Args {..} = do
      putStrLn "Comparing:"
      putStrLn $ "1: " ++ argCabal1 ++ " " ++ unwords argCabal1Flags
      callProcess argCabal1 ["--version"]
      putStrLn $ "2: " ++ argCabal2 ++ " " ++ unwords argCabal2Flags
      callProcess argCabal2 ["--version"]
      -- TODO: Print index state.
      putStrLn "Base package database:"
      callProcess "ghc-pkg" ["list"]

    getPackages :: Args -> IO [PackageName]
    getPackages Args {..} = do
      pkgs <-
          if null argPackages
          then do
            putStrLn $ "Obtaining the package list (using " ++ argCabal1 ++ ") ..."
            list <- readProcess argCabal1 ["list", "--simple-output"] ""
            return $ nub [mkPackageName $ head (words line) | line <- lines list]
          else do
            putStrLn "Using given package list ..."
            return argPackages
      putStrLn $ "Done, got " ++ show (length pkgs) ++ " packages."
      return pkgs

data CabalUnderTest = CabalUnderTest1 | CabalUnderTest2

runCabal
    :: Int             -- ^ timeout in seconds
    -> CabalUnderTest  -- ^ cabal under test
    -> FilePath        -- ^ cabal
    -> [String]        -- ^ flags
    -> IO (PackageName  -> IO CabalTrial)  -- ^ testing function.
runCabal timeoutSeconds cabalUnderTest cabal flags = do
  tmpDir <- getTemporaryDirectory

  -- cabal directory for this cabal under test
  let cabalDir = tmpDir </> "solver-benchmarks-workdir" </> case cabalUnderTest of
          CabalUnderTest1 -> "cabal1"
          CabalUnderTest2 -> "cabal2"

  putStrLn $ "Cabal directory (for " ++ cabal ++ ") " ++ cabalDir
  createDirectoryIfMissing True cabalDir

  -- shell enviroment
  currEnv <- Map.fromList <$>  getEnvironment
  let thisEnv :: [(String, String)]
      thisEnv = Map.toList $ currEnv
          & Map.insert "CABAL_CONFIG" (cabalDir </> "config")
          & Map.insert "CABAL_DIR"     cabalDir

  -- Run cabal update,
  putStrLn $ "Running cabal update (using " ++ cabal ++ ") ..."
  (ec, uout, uerr) <- readCreateProcessWithExitCode (proc cabal ["update"])
      { cwd = Just cabalDir
      , env = Just thisEnv
      }
      ""
  unless (ec == ExitSuccess) $ do
      putStrLn uout
      putStrLn uerr
      exitWith ec

  -- return an actual runner
  return $ \pkg -> do
    ((exitCode, err), time) <- timeEvent $ do

      let timeout = "timeout --foreground -sINT " ++ show timeoutSeconds
          cabalCmd = unwords $
              [ cabal

              , "v2-install"

                -- These flags prevent a Cabal project or package environment from
                -- affecting the install plan.
                --
                -- Note: we are somewhere in /tmp, hopefully there is no cabal.project on upper level
              , "--package-env=non-existent-package-env"

                -- --lib allows solving for packages with libraries or
                -- executables.
              , "--lib"

              , unPackageName pkg

              , "--dry-run"

                -- The test doesn't currently handle stdout, so we suppress it
                -- with silent. nowrap simplifies parsing the errors messages.
              , "-vsilent+nowrap"

              ]

               ++ flags

          cmd = (shell (timeout ++ " " ++ cabalCmd))
              { std_err = CreatePipe
              , env = Just thisEnv
              , cwd = Just cabalDir
              }

      -- TODO: Read stdout and compare the install plans.
      (_, _, Just errh, ph) <- createProcess cmd
      err <- BS.hGetContents errh
      (, err) <$> waitForProcess ph

    let exhaustiveMsg =
            "After searching the rest of the dependency tree exhaustively"
        result
          | exitCode == ExitSuccess                                                          = Solution
          | exitCode == ExitFailure 124                                                      = Timeout
          | fromString exhaustiveMsg `BS.isInfixOf` err                                       = NoInstallPlan
          | fromString "Backjump limit reached" `BS.isInfixOf` err                            = BackjumpLimit
          | fromString "none of the components are available to build" `BS.isInfixOf` err     = Unbuildable
          | fromString "Dependency on unbuildable" `BS.isInfixOf` err                         = UnbuildableDep
          | fromString "Dependency cycle between the following components" `BS.isInfixOf` err = ComponentCycle
          | fromString "Problem with module re-exports" `BS.isInfixOf` err                    = ModReexpIssue
          | fromString "There is no package named" `BS.isInfixOf` err                         = PkgNotFound
          | otherwise                                                                        = Unknown
    return (CabalTrial time result)

isSampleLargeEnough :: PValue Double -> Int -> Bool
isSampleLargeEnough pvalue trials =
    -- mannWhitneyUCriticalValue, which can fail with too few samples, is only
    -- used when both sample sizes are less than or equal to 20.
    trials > 20 || isJust (mannWhitneyUCriticalValue (trials, trials) pvalue)

isSignificantTimeDifference :: PValue Double -> [NominalDiffTime] -> [NominalDiffTime] -> Bool
isSignificantTimeDifference pvalue xs ys =
  let toVector = V.fromList . map diffTimeToDouble
  in case mannWhitneyUtest SamplesDiffer pvalue (toVector xs) (toVector ys) of
       Nothing             -> error "not enough data for mannWhitneyUtest"
       Just Significant    -> True
       Just NotSignificant -> False

-- Should we stop after the first trial of this package to save time? This
-- function skips the package if the results are uninteresting and the times are
-- within --min-run-time-percentage-difference-to-rerun.
shouldContinueAfterFirstTrial :: Double
                              -> NominalDiffTime
                              -> NominalDiffTime
                              -> CabalResult
                              -> CabalResult
                              -> Bool
shouldContinueAfterFirstTrial 0                            _  _  _       _       = True
shouldContinueAfterFirstTrial _                            _  _  Timeout Timeout = False
shouldContinueAfterFirstTrial maxRunTimeDifferenceToIgnore t1 t2 r1      r2      =
    isSignificantResult r1 r2
 || abs (t1 - t2) / min t1 t2 >= realToFrac (maxRunTimeDifferenceToIgnore / 100)

isSignificantResult :: CabalResult -> CabalResult -> Bool
isSignificantResult r1 r2 = r1 /= r2 || not (isExpectedResult r1)

-- Is this result expected in a benchmark run on all of Hackage?
isExpectedResult :: CabalResult -> Bool
isExpectedResult Solution       = True
isExpectedResult NoInstallPlan  = True
isExpectedResult BackjumpLimit  = True
isExpectedResult Timeout        = True
isExpectedResult Unbuildable    = True
isExpectedResult UnbuildableDep = True
isExpectedResult ComponentCycle = True
isExpectedResult ModReexpIssue  = True
isExpectedResult PkgNotFound    = False
isExpectedResult Unknown        = False

-- Combine CabalResults from multiple trials. Ignoring timeouts, all results
-- should be the same. If they aren't the same, we returns Unknown.
combineTrialResults :: [CabalResult] -> CabalResult
combineTrialResults rs
  | allEqual rs                          = head rs
  | allEqual [r | r <- rs, r /= Timeout] = Timeout
  | otherwise                            = Unknown
  where
    allEqual :: Eq a => [a] -> Bool
    allEqual xs = length (nub xs) == 1

timeEvent :: IO a -> IO (a, NominalDiffTime)
timeEvent task = do
  start <- getCurrentTime
  r <- task
  end <- getCurrentTime
  return (r, diffUTCTime end start)

diffTimeToDouble :: NominalDiffTime -> Double
diffTimeToDouble = fromRational . toRational

parserInfo :: ParserInfo Args
parserInfo = info (argParser <**> helper)
     ( fullDesc
    <> progDesc ("Find differences between two cabal commands when solving"
                   ++ " for all packages on Hackage.")
    <> header "hackage-benchmark" )

argParser :: Parser Args
argParser = Args
    <$> strOption
         ( long "cabal1"
        <> metavar "PATH"
        <> help "First cabal executable")
    <*> strOption
         ( long "cabal2"
        <> metavar "PATH"
        <> help "Second cabal executable")
    <*> option (words <$> str)
         ( long "cabal1-flags"
        <> value []
        <> metavar "FLAGS"
        <> help "Extra flags for the first cabal executable")
    <*> option (words <$> str)
         ( long "cabal2-flags"
        <> value []
        <> metavar "FLAGS"
        <> help "Extra flags for the second cabal executable")
    <*> option (map mkPackageName . words <$> str)
         ( long "packages"
        <> value []
        <> metavar "PACKAGES"
        <> help ("Space separated list of packages to test, or all of Hackage"
                   ++ " if unspecified"))
    <*> option auto
         ( long "min-run-time-percentage-difference-to-rerun"
        <> showDefault
        <> value 0.0
        <> metavar "PERCENTAGE"
        <> help ("Stop testing a package when the difference in run times in"
                   ++ " the first trial are within this percentage, in order to"
                   ++ " save time"))
    <*> option (mkPValue <$> auto)
         ( long "pvalue"
        <> showDefault
        <> value (mkPValue 0.05)
        <> metavar "DOUBLE"
        <> help ("p-value used to determine whether to print the results for"
                   ++ " each package"))
    <*> option auto
         ( long "trials"
        <> showDefault
        <> value 10
        <> metavar "N"
        <> help "Number of trials for each package")
    <*> switch
         ( long "concurrently"
        <> help "Run cabals concurrently")
    <*> switch
         ( long "print-trials"
        <> help "Whether to include the results from individual trials in the output")
    <*> switch
         ( long "print-skipped-packages"
        <> help "Whether to include skipped packages in the output")
    <*> option auto
         ( long "timeout"
        <> showDefault
        <> value 90
        <> metavar "SECONDS"
        <> help "Maximum time to run a cabal command, in seconds")
