{-|
  Top-Level Pier Management

  This is the code that starts the IO drivers and deals with communication
  between the serf, the event log, and the IO drivers.
-}
module Urbit.Vere.Pier
  ( booted
  , runSerf
  , resumed
  , getSnapshot
  , pier
  , runPersist
  , runCompute
  , genBootSeq
  )
where

import Urbit.Prelude

import Control.Monad.Trans.Maybe
import RIO.Directory
import Urbit.Arvo
import Urbit.King.Config
import Urbit.Vere.Pier.Types

import Data.Text              (append)
import System.Posix.Files     (ownerModes, setFileMode)
import Urbit.King.App         (HasKingEnv, HasPierEnv(..), PierEnv)
import Urbit.King.App         (onKillPierSigL)
import Urbit.Time             (Wen)
import Urbit.Vere.Ames        (ames)
import Urbit.Vere.Behn        (behn)
import Urbit.Vere.Clay        (clay)
import Urbit.Vere.Eyre        (eyre)
import Urbit.Vere.Eyre.Multi  (MultiEyreApi)
import Urbit.Vere.Http.Client (client)
import Urbit.Vere.Log         (EventLog)
import Urbit.Vere.Serf        (Serf)

import qualified System.Entropy         as Ent
import qualified Urbit.King.API         as King
import qualified Urbit.Time             as Time
import qualified Urbit.Vere.Log         as Log
import qualified Urbit.Vere.Serf        as Serf
import qualified Urbit.Vere.Term        as Term
import qualified Urbit.Vere.Term.API    as Term
import qualified Urbit.Vere.Term.Demux  as Term
import qualified Urbit.Vere.Term.Render as Term


-- Initialize pier directory. --------------------------------------------------

data PierDirectoryAlreadyExists = PierDirectoryAlreadyExists
 deriving (Show, Exception)

setupPierDirectory :: FilePath -> RIO e ()
setupPierDirectory shipPath = do
  -- shipPath will already exist because we put a lock file there.
  alreadyExists <- doesPathExist (shipPath </> ".urb")
  when alreadyExists $ do
    throwIO PierDirectoryAlreadyExists
  for_ ["put", "get", "log", "chk"] $ \seg -> do
    let pax = shipPath </> ".urb" </> seg
    createDirectoryIfMissing True pax
    io $ setFileMode pax ownerModes


-- Load pill into boot sequence. -----------------------------------------------

genEntropy :: RIO e Word512
genEntropy = fromIntegral . bytesAtom <$> io (Ent.getEntropy 64)

genBootSeq :: Ship -> Pill -> Bool -> LegacyBootEvent -> RIO e BootSeq
genBootSeq ship Pill {..} lite boot = do
  ent <- genEntropy
  let ovums = preKern ent <> pKernelOvums <> postKern <> pUserspaceOvums
  pure $ BootSeq ident pBootFormulas ovums
 where
  ident = LogIdentity ship isFake (fromIntegral $ length pBootFormulas)
  preKern ent =
    [ EvBlip $ BlipEvArvo $ ArvoEvWhom () ship
    , EvBlip $ BlipEvArvo $ ArvoEvWack () ent
    ]
  postKern = [EvBlip $ BlipEvTerm $ TermEvBoot (1, ()) lite boot]
  isFake   = case boot of
    Fake _ -> True
    _      -> False


-- Write a batch of jobs into the event log ------------------------------------

writeJobs :: EventLog -> Vector Job -> RIO e ()
writeJobs log !jobs = do
  expect <- atomically (Log.nextEv log)
  events <- fmap fromList $ traverse fromJob (zip [expect ..] $ toList jobs)
  Log.appendEvents log events
 where
  fromJob :: (EventId, Job) -> RIO e ByteString
  fromJob (expectedId, job) = do
    unless (expectedId == jobId job) $ error $ show
      ("bad job id!", expectedId, jobId job)
    pure $ jamBS $ jobPayload job

  jobPayload :: Job -> Noun
  jobPayload (RunNok (LifeCyc _ m n)) = toNoun (m, n)
  jobPayload (DoWork (Work _ m d o )) = toNoun (m, d, o)


-- Acquire a running serf. -----------------------------------------------------

printTank :: (Text -> IO ()) -> Atom -> Tank -> IO ()
printTank f _ = io . f . unlines . fmap unTape . wash (WashCfg 0 80)

runSerf
  :: HasLogFunc e
  => TVar (Text -> IO ())
  -> FilePath
  -> [Serf.Flag]
  -> RAcquire e Serf
runSerf vSlog pax fax = do
  env <- ask
  Serf.withSerf (config env)
 where
  slog txt = join $ atomically (readTVar vSlog >>= pure . ($ txt))
  config env = Serf.Config
    { scSerf = "urbit-worker" -- TODO Find the executable in some proper way.
    , scPier = pax
    , scFlag = fax
    , scSlog = \(pri, tank) -> printTank slog pri tank
    , scStdr = \line -> runRIO env $ logTrace (display ("SERF: " <> line))
    , scDead = pure () -- TODO: What can be done?
    }


-- Boot a new ship. ------------------------------------------------------------

booted
  :: TVar (Text -> IO ())
  -> Pill
  -> Bool
  -> [Serf.Flag]
  -> Ship
  -> LegacyBootEvent
  -> RAcquire PierEnv (Serf, EventLog)
booted vSlog pill lite flags ship boot = do
  rio $ bootNewShip pill lite flags ship boot
  resumed vSlog Nothing flags

bootSeqJobs :: Time.Wen -> BootSeq -> [Job]
bootSeqJobs now (BootSeq ident nocks ovums) = zipWith ($) bootSeqFns [1 ..]
 where
  wen :: EventId -> Time.Wen
  wen off = Time.addGap now ((fromIntegral off - 1) ^. from Time.microSecs)

  bootSeqFns :: [EventId -> Job]
  bootSeqFns = fmap muckNock nocks <> fmap muckOvum ovums
   where
    muckNock nok eId = RunNok $ LifeCyc eId 0 nok
    muckOvum ov eId = DoWork $ Work eId 0 (wen eId) ov

bootNewShip
  :: HasPierEnv e
  => Pill
  -> Bool
  -> [Serf.Flag]
  -> Ship
  -> LegacyBootEvent
  -> RIO e ()
bootNewShip pill lite flags ship bootEv = do
  seq@(BootSeq ident x y) <- genBootSeq ship pill lite bootEv
  logTrace "BootSeq Computed"

  pierPath <- view pierPathL

  liftRIO (setupPierDirectory pierPath)
  logTrace "Directory setup."

  rwith (Log.new (pierPath <> "/.urb/log") ident) $ \log -> do
    logTrace "Event log initialized."
    jobs <- (\now -> bootSeqJobs now seq) <$> io Time.now
    writeJobs log (fromList jobs)

  logTrace "Finsihed populating event log with boot sequence"


-- Resume an existing ship. ----------------------------------------------------

resumed
  :: TVar (Text -> IO ())
  -> Maybe Word64
  -> [Serf.Flag]
  -> RAcquire PierEnv (Serf, EventLog)
resumed vSlog replayUntil flags  = do
  rio $ logTrace "Resuming ship"
  top <- view pierPathL
  tap <- fmap (fromMaybe top) $ rio $ runMaybeT $ do
    ev <- MaybeT (pure replayUntil)
    MaybeT (getSnapshot top ev)

  rio $ logTrace $ display @Text ("pier: " <> pack top)
  rio $ logTrace $ display @Text ("running serf in: " <> pack tap)

  log  <- Log.existing (top <> "/.urb/log")
  serf <- runSerf vSlog tap flags

  rio $ do
    logTrace "Replaying events"
    Serf.execReplay serf log replayUntil
    logTrace "Taking snapshot"
    io (Serf.snapshot serf)
    logTrace "Shuting down the serf"

  pure (serf, log)

getSnapshot :: forall e . FilePath -> Word64 -> RIO e (Maybe FilePath)
getSnapshot top last = do
  lastSnapshot <- lastMay <$> listReplays
  pure (replayToPath <$> lastSnapshot)
 where
  replayDir = top </> ".partial-replay"
  replayToPath eId = replayDir </> show eId

  listReplays :: RIO e [Word64]
  listReplays = do
    createDirectoryIfMissing True replayDir
    snapshotNums <- mapMaybe readMay <$> listDirectory replayDir
    pure $ sort (filter (<= fromIntegral last) snapshotNums)


-- Utils for Spawning Worker Threads -------------------------------------------

acquireWorker :: HasLogFunc e => Text -> RIO e () -> RAcquire e (Async ())
acquireWorker nam act = mkRAcquire (async act) kill
 where
  kill tid = do
    logTrace ("Killing worker thread: " <> display nam)
    cancel tid
    logTrace ("Killed worker thread: " <> display nam)

acquireWorkerBound :: HasLogFunc e => Text -> RIO e () -> RAcquire e (Async ())
acquireWorkerBound nam act = mkRAcquire (asyncBound act) kill
 where
  kill tid = do
    logTrace ("Killing worker thread: " <> display nam)
    cancel tid
    logTrace ("Killed worker thread: " <> display nam)


-- Run Pier --------------------------------------------------------------------

pier
  :: (Serf, EventLog)
  -> TVar (Text -> IO ())
  -> MVar ()
  -> MultiEyreApi
  -> RAcquire PierEnv ()
pier (serf, log) vSlog mStart multi = do
  computeQ <- newTQueueIO @_ @Serf.EvErr
  persistQ <- newTQueueIO
  executeQ <- newTQueueIO
  saveM    <- newEmptyTMVarIO
  kingApi  <- King.kingAPI

  termApiQ <- atomically $ do
    q <- newTQueue
    writeTVar (King.kTermConn kingApi) (Just $ writeTQueue q)
    pure q

  (demux, muxed) <- atomically $ do
    res <- Term.mkDemux
    pure (res, Term.useDemux res)

  acquireWorker "TERMSERV" $ forever $ do
    logTrace "TERMSERV Waiting for external terminal."
    atomically $ do
      ext <- Term.connClient <$> readTQueue termApiQ
      Term.addDemux ext demux
    logTrace "TERMSERV External terminal connected."

  --  Slogs go to both stderr and to the terminal.
  atomically $ do
    oldSlog <- readTVar vSlog
    writeTVar vSlog $ \txt -> do
      atomically $ Term.trace muxed txt
      oldSlog txt

  let logId   = Log.identity log
  let ship    = who logId

  -- Our call above to set the logging function which echos errors from the
  -- Serf doesn't have the appended \r\n because those \r\n s are added in
  -- the c serf code. Logging output from our haskell process must manually
  -- add them.
  let showErr = atomically . Term.trace muxed . (flip append "\r\n")

  env <- ask

  let (bootEvents, startDrivers) = drivers
        env
        multi
        ship
        (isFake logId)
        (writeTQueue computeQ)
        (Term.TSize { tsWide = 80, tsTall = 24 }, muxed)
        showErr

  io $ atomically $ for_ bootEvents (writeTQueue computeQ)

  scryM  <- newEmptyTMVarIO
  onKill <- view onKillPierSigL

  let computeConfig = ComputeConfig { ccOnWork      = readTQueue computeQ
                                    , ccOnKill      = onKill
                                    , ccOnSave      = takeTMVar saveM
                                    , ccOnScry      = takeTMVar scryM
                                    , ccPutResult   = writeTQueue persistQ
                                    , ccShowSpinner = Term.spin muxed
                                    , ccHideSpinner = Term.stopSpin muxed
                                    , ccLastEvInLog = Log.lastEv log
                                    }

  let plan = writeTQueue executeQ

  drivz       <- startDrivers
  tExec       <- acquireWorker "Effects" (router (readTQueue executeQ) drivz)
  tDisk       <- acquireWorkerBound "Persist" (runPersist log persistQ plan)
  tSerf       <- acquireWorker "Serf" (runCompute serf computeConfig)

  tSaveSignal <- saveSignalThread saveM

  --  TODO bullshit scry tester
  void $ acquireWorker "bullshit scry tester" $ forever $ do
    env <- ask
    threadDelay 15_000_000
    wen <- io Time.now
    let kal = \mTermNoun -> runRIO env $ do
          logTrace $ displayShow ("scry result: ", mTermNoun)
    let nkt = MkKnot $ tshow $ Time.MkDate wen
    let pax = Path ["j", "~zod", "life", nkt, "~zod"]
    atomically $ putTMVar scryM (wen, Nothing, pax, kal)

  putMVar mStart ()

  -- Wait for something to die.

  let ded = asum
        [ death "effects thread" tExec
        , death "persist thread" tDisk
        , death "compute thread" tSerf
        ]

  atomically ded >>= \case
    Left  (txt, exn) -> logError $ displayShow ("Somthing died", txt, exn)
    Right tag        -> logError $ displayShow ("Something simply exited", tag)

  atomically $ (Term.spin muxed) (Just "shutdown")


death :: Text -> Async () -> STM (Either (Text, SomeException) Text)
death tag tid = do
  waitCatchSTM tid <&> \case
    Left  exn -> Left (tag, exn)
    Right ()  -> Right tag

saveSignalThread :: TMVar () -> RAcquire e (Async ())
saveSignalThread tm = mkRAcquire start cancel
 where
  start = async $ forever $ do
    threadDelay (120 * 1000000) -- 120 seconds
    atomically $ putTMVar tm ()


-- Start All Drivers -----------------------------------------------------------

data Drivers e = Drivers
  { dAmes :: AmesEf -> IO ()
  , dBehn :: BehnEf -> IO ()
  , dIris :: HttpClientEf -> IO ()
  , dEyre :: HttpServerEf -> IO ()
  , dNewt :: NewtEf -> IO ()
  , dSync :: SyncEf -> IO ()
  , dTerm :: TermEf -> IO ()
  }

drivers
  :: HasPierEnv e
  => e
  -> MultiEyreApi
  -> Ship
  -> Bool
  -> (EvErr -> STM ())
  -> (Term.TSize, Term.Client)
  -> (Text -> RIO e ())
  -> ([EvErr], RAcquire e (Drivers e))
drivers env multi who isFake plan termSys stderr =
  (initialEvents, runDrivers)
 where
  (behnBorn, runBehn) = behn env plan
  (amesBorn, runAmes) = ames env who isFake plan stderr
  (httpBorn, runEyre) = eyre env multi who plan isFake
  (clayBorn, runClay) = clay env plan
  (irisBorn, runIris) = client env plan
  (termBorn, runTerm) = Term.term env termSys plan
  initialEvents       = mconcat [behnBorn, clayBorn, amesBorn, httpBorn,
                                 termBorn, irisBorn]

  runDrivers          = do
    dNewt <- runAmes
    dBehn <- liftAcquire $ runBehn
    dAmes <- pure $ const $ pure ()
    dIris <- runIris
    dEyre <- runEyre
    dSync <- runClay
    dTerm <- runTerm
    pure (Drivers{..})


-- Route Effects to Drivers ----------------------------------------------------

router :: HasLogFunc e => STM FX -> Drivers e -> RIO e ()
router waitFx Drivers {..} = forever $ do
  fx <- atomically waitFx
  for_ fx $ \ef -> do
    logEffect ef
    case ef of
      GoodParse (EfVega _ _              ) -> error "TODO"
      GoodParse (EfExit _ _              ) -> error "TODO"
      GoodParse (EfVane (VEAmes       ef)) -> io (dAmes ef)
      GoodParse (EfVane (VEBehn       ef)) -> io (dBehn ef)
      GoodParse (EfVane (VEBoat       ef)) -> io (dSync ef)
      GoodParse (EfVane (VEClay       ef)) -> io (dSync ef)
      GoodParse (EfVane (VEHttpClient ef)) -> io (dIris ef)
      GoodParse (EfVane (VEHttpServer ef)) -> io (dEyre ef)
      GoodParse (EfVane (VENewt       ef)) -> io (dNewt ef)
      GoodParse (EfVane (VESync       ef)) -> io (dSync ef)
      GoodParse (EfVane (VETerm       ef)) -> io (dTerm ef)
      FailParse n -> logError $ display $ pack @Text (ppShow n)


-- Compute (Serf) Thread -------------------------------------------------------

logEvent :: HasLogFunc e => Ev -> RIO e ()
logEvent ev = logDebug $ display $ "[EVENT]\n" <> pretty
 where
  pretty :: Text
  pretty = pack $ unlines $ fmap ("\t" <>) $ lines $ ppShow ev

logEffect :: HasLogFunc e => Lenient Ef -> RIO e ()
logEffect ef = logDebug $ display $ "[EFFECT]\n" <> pretty ef
 where
  pretty :: Lenient Ef -> Text
  pretty = \case
    GoodParse e -> pack $ unlines $ fmap ("\t" <>) $ lines $ ppShow e
    FailParse n -> pack $ unlines $ fmap ("\t" <>) $ lines $ ppShow n

data ComputeConfig = ComputeConfig
  { ccOnWork      :: STM Serf.EvErr
  , ccOnKill      :: STM ()
  , ccOnSave      :: STM ()
  , ccOnScry      :: STM (Wen, Gang, Path, Maybe (Term, Noun) -> IO ())
  , ccPutResult   :: (Fact, FX) -> STM ()
  , ccShowSpinner :: Maybe Text -> STM ()
  , ccHideSpinner :: STM ()
  , ccLastEvInLog :: STM EventId
  }

runCompute :: forall e . HasKingEnv e => Serf.Serf -> ComputeConfig -> RIO e ()
runCompute serf ComputeConfig {..} = do
  logTrace "runCompute"

  let onCR = asum [ ccOnKill <&> Serf.RRKill
                  , ccOnSave <&> Serf.RRSave
                  , ccOnWork <&> Serf.RRWork
                  , ccOnScry <&> \(w,g,p,k) -> Serf.RRScry w g p k
                  ]

  vEvProcessing :: TMVar Ev <- newEmptyTMVarIO

  void $ async $ forever (atomically (takeTMVar vEvProcessing) >>= logEvent)

  let onSpin :: Maybe Ev -> STM ()
      onSpin = \case
        Nothing -> ccHideSpinner
        Just ev -> do
          ccShowSpinner (getSpinnerNameForEvent ev)
          putTMVar vEvProcessing ev

  let maxBatchSize = 10

  io (Serf.run serf maxBatchSize ccLastEvInLog onCR ccPutResult onSpin)


-- Event-Log Persistence Thread ------------------------------------------------

data PersistExn = BadEventId EventId EventId
  deriving Show

instance Exception PersistExn where
  displayException (BadEventId expected got) =
    unlines [ "Out-of-order event id send to persist thread."
            , "\tExpected " <> show expected <> " but got " <> show got
            ]

runPersist
  :: forall e
   . HasPierEnv e
  => EventLog
  -> TQueue (Fact, FX)
  -> (FX -> STM ())
  -> RIO e ()
runPersist log inpQ out = do
  dryRun <- view dryRunL
  forever $ do
    writs  <- atomically getBatchFromQueue
    events <- validateFactsAndGetBytes (fst <$> toNullable writs)
    unless dryRun (Log.appendEvents log events)
    atomically $ for_ writs $ \(_, fx) -> do
      out fx

 where
  validateFactsAndGetBytes :: [Fact] -> RIO e (Vector ByteString)
  validateFactsAndGetBytes facts = do
    expect <- atomically (Log.nextEv log)
    lis <- for (zip [expect ..] facts) $ \(expectedId, Fact eve mug wen non) ->
      do
        unless (expectedId == eve) $ do
          throwIO (BadEventId expectedId eve)
        pure $ jamBS $ toNoun (mug, wen, non)
    pure (fromList lis)

  getBatchFromQueue :: STM (NonNull [(Fact, FX)])
  getBatchFromQueue = readTQueue inpQ >>= go . singleton
   where
    go acc = tryReadTQueue inpQ >>= \case
      Nothing   -> pure (reverse acc)
      Just item -> go (item <| acc)
