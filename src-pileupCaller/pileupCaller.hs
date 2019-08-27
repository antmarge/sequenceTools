{-# LANGUAGE OverloadedStrings #-}

import SequenceFormats.Eigenstrat (readEigenstratSnpFile, EigenstratSnpEntry(..), 
    EigenstratIndEntry(..), Sex(..), writeEigenstrat)
import SequenceFormats.FreqSum(FreqSumEntry(..), printFreqSumStdOut, FreqSumHeader(..))
import SequenceFormats.Pileup (PileupRow(..), readPileupFromStdIn)

import SequenceTools.Utils (versionInfoOpt, versionInfoText)
import SequenceTools.PileupCaller (CallingMode(..), callGenotypeFromPileup, callToDosage,
    freqSumToEigenstrat)

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (ReaderT, runReaderT, asks)
import qualified Data.ByteString.Char8 as B
import Data.List.Split (splitOn)
import qualified Options.Applicative as OP
import Pipes (Pipe, yield, (>->), runEffect, Producer, Pipe, for, cat)
import Pipes.OrderedZip (orderedZip)
import qualified Pipes.Prelude as P
import Pipes.Safe (runSafeT, SafeT)
import System.Random (mkStdGen, setStdGen)

data ProgOpt = ProgOpt {
    optCallingMode :: CallingMode,
    optSeed :: Maybe Int,
    optMinDepth :: Int,
    optTransitionsMode :: TransitionsMode,
    optSnpFile :: FilePath,
    optOutFormat :: OutFormat,
    optSampleNames :: Either [String] FilePath,
    optSamplePopName :: String
}

data TransitionsMode = TransitionsMissing | SkipTransitions | AllSites
data OutFormat = EigenstratFormat String | FreqSumFormat
type App = ReaderT ProgOpt (SafeT IO)

main :: IO ()
main = OP.execParser parserInfo >>= runSafeT . runReaderT runWithOpts
  where
    parserInfo = OP.info (pure (.) <*> versionInfoOpt <*> OP.helper <*> argParser)
        (OP.progDesc versionInfoText)

runWithOpts :: App ()
runWithOpts = do
    setRandomSeed
    let pileupProducer = readPileupFromStdIn
    snpFile <- asks optSnpFile
    freqSumProducer <- pileupToFreqSum snpFile pileupProducer
    outFormat <- asks optOutFormat
    case outFormat of
        FreqSumFormat -> outputFreqSum freqSumProducer
        EigenstratFormat outPrefix -> outputEigenStrat outPrefix freqSumProducer

setRandomSeed :: App ()
setRandomSeed = do
    seed <- asks optSeed
    case seed of
        Nothing -> return ()
        Just seed_ -> liftIO . setStdGen $ mkStdGen seed_

pileupToFreqSum :: FilePath -> Producer PileupRow (SafeT IO) () -> App (Producer FreqSumEntry (SafeT IO) ())
pileupToFreqSum snpFileName pileupProducer = do
    sampleNameSpec <- asks optSampleNames
    sampleNames <- case sampleNameSpec of
        Left list -> return list
        Right fn -> liftIO (lines <$> readFile fn)
    let snpProd = readEigenstratSnpFile snpFileName
        jointProd = orderedZip cmp snpProd pileupProducer
    mode <- asks optCallingMode
    minDepth <- asks optMinDepth
    let ret = for jointProd $ \jointEntry ->
            case jointEntry of
                (Just (EigenstratSnpEntry snpChrom_ snpPos_ _ _ snpRef_ snpAlt_), Nothing) ->
                    yield $ FreqSumEntry snpChrom_ snpPos_ snpRef_ snpAlt_
                            (replicate (length sampleNames) Nothing)
                (Just (EigenstratSnpEntry snpChrom_ snpPos_ _ _ snpRef_ snpAlt_),
                 Just pileupRow) -> do
                    let PileupRow _ _ _ entryPerSample = pileupRow
                    calls <- liftIO $ mapM (callGenotypeFromPileup mode minDepth) entryPerSample
                    let genotypes = map (callToDosage snpRef_ snpAlt_) calls
                    yield (FreqSumEntry snpChrom_ snpPos_ snpRef_ snpAlt_ genotypes)
                _ -> return ()
    return (fst <$> ret)
  where
    cmp (EigenstratSnpEntry snpChrom_ snpPos_ _ _ _ _) (PileupRow pChrom pPos _ _) =
        (snpChrom_, snpPos_) `compare` (pChrom, pPos)

outputFreqSum :: Producer FreqSumEntry (SafeT IO) () -> App ()
outputFreqSum freqSumProducer = do
    transitionsOnly <- asks optTransitionsMode
    sampleNameSpec <- asks optSampleNames
    callingMode <- asks optCallingMode
    sampleNames <- case sampleNameSpec of
        Left list -> return list
        Right fn -> fmap lines . liftIO $ readFile fn
    let nrHaplotypes = case callingMode of
            MajorityCalling _ -> 1 :: Int
            RandomCalling -> 1
            RandomDiploidCalling -> 2
    let header' = FreqSumHeader (map B.pack sampleNames) [nrHaplotypes | _ <- sampleNames]
        outProd = freqSumProducer >-> filterTransitions transitionsOnly
    lift . runEffect $ outProd >-> printFreqSumStdOut header'

outputEigenStrat :: FilePath -> Producer FreqSumEntry (SafeT IO) () -> App ()
outputEigenStrat outPrefix freqSumProducer = do
    transitionsMode <- asks optTransitionsMode
    sampleNameSpec <- asks optSampleNames
    callingMode <- asks optCallingMode
    let diploidizeCall = case callingMode of
            RandomCalling -> True
            MajorityCalling _ -> True
            RandomDiploidCalling -> False
    sampleNames <- case sampleNameSpec of
        Left list -> return list
        Right fn -> lines <$> (liftIO . readFile) fn
    let snpOut = outPrefix <> "snp.txt"
        indOut = outPrefix <> "ind.txt"
        genoOut = outPrefix <> "geno.txt"
    p <- asks optSamplePopName
    let indEntries = [EigenstratIndEntry n Unknown p | n <- sampleNames]
    lift . runEffect $ freqSumProducer >-> filterTransitions transitionsMode >->
                P.map (freqSumToEigenstrat diploidizeCall) >->
                writeEigenstrat genoOut snpOut indOut indEntries

filterTransitions :: TransitionsMode ->
    Pipe FreqSumEntry FreqSumEntry (SafeT IO) ()
filterTransitions transversionsMode =
    case transversionsMode of
        SkipTransitions ->
            P.filter (\(FreqSumEntry _ _ ref alt _) -> isTransversion ref alt)
        TransitionsMissing ->
            P.map (\(FreqSumEntry chrom pos ref alt calls) ->
                let calls' = if isTransversion ref alt then calls else [Nothing | _ <- calls]
                in  FreqSumEntry chrom pos ref alt calls')
        AllSites -> cat
  where
    isTransversion ref alt = not $ isTransition ref alt
    isTransition ref alt = ((ref == 'A') && (alt == 'G')) ||
        ((ref == 'G') && (alt == 'A')) || ((ref == 'C') && (alt == 'T')) ||
        ((ref == 'T') && (alt == 'C'))

argParser :: OP.Parser ProgOpt
argParser = ProgOpt <$> parseCallingMode <*> parseSeed <*> parseMinDepth <*>
    parseTransitionsMode <*> parseSnpFile <*> parseFormat <*> parseSampleNames <*> 
    parseSamplePopName
  where
    parseCallingMode = parseRandomCalling <|> parseMajorityCalling <|> parseRandomDiploidCalling
    parseRandomCalling = OP.flag' RandomCalling (OP.long "randomHaploid" <>
        OP.help "This method samples one read at random at each site, and uses the allele \
        \on that read as the one for the actual genotype. This results in a haploid \
        \call")
    parseRandomDiploidCalling = OP.flag' RandomDiploidCalling (OP.long "randomDiploid" <>
        OP.help "Sample two random reads at random and represent the \
        \individual by the diploid genotype constructed from those two random \
        \picks. This will always assign missing data to positions where only \
        \one read is present, even if minDepth=1.")
    parseMajorityCalling = MajorityCalling <$> (parseMajorityCallingFlag *> parseDownsamplingFlag)
    parseMajorityCallingFlag = OP.flag' True (OP.long "majorityCall" <> OP.help
        "Pick the allele supported by the \
        \most reads at a site. If an equal numbers of Alleles fulfil this, pick one at \
        \random. This results in a haploid call.")
    parseDownsamplingFlag = OP.switch (OP.long "downSampling" <> OP.help "When this switch is given, the MajorityCalling mode with downsample \
        \from the total number of reads a number of reads \
        \(without replacement) equal to the --minDepth given. This mitigates \
        \reference bias in the MajorityCalling model, which increases with higher coverage.")
    parseSeed = OP.option (Just <$> OP.auto) (OP.long "seed" <>
        OP.value Nothing <> OP.metavar "<RANDOM_SEED>" <>
        OP.help "random seed used for random calling. If not given, use \
        \system clock to seed the random number generator")
    parseMinDepth = OP.option OP.auto (OP.long "minDepth" <> OP.short 'd' <>
        OP.value 1 <> OP.showDefault <> OP.metavar "<DEPTH>" <>
        OP.help "specify the minimum depth for a call. For sites with fewer \
            \reads than this number, declare Missing")
    parseTransitionsMode = parseSkipTransitions <|> parseTransitionsMissing <|> pure AllSites
    parseSkipTransitions = OP.flag' SkipTransitions (OP.long "skipTransitions" <> OP.help "skip transition SNPs entirely in the output, resulting in a dataset with fewer sites.\
        \ If neither option --skipTransitions nor --transitionsMissing is set, output all sites")
    parseTransitionsMissing = OP.flag' TransitionsMissing (OP.long "transitionsMissing" <> OP.help "mark transitions as missing in the output, but do output the sites. \
        \If neither option --skipTransitions nor --transitionsMissing is set, output all sites")
    parseSnpFile = OP.strOption (OP.long "snpFile" <> OP.short 'f' <>
        OP.metavar "<FILE>" <> OP.help "specify an Eigenstrat SNP file for \
        \the positions and alleles to call. All \
        \positions in the SNP file will be output, adding missing data where \
        \necessary. Note that pileupCaller automatically checks whether \
        \alleles in the SNP file are flipped with respect to the human \
        \reference. But it assumes that the strand-orientation is the same.")
    parseFormat = (EigenstratFormat <$> parseEigenstratPrefix) <|> pure FreqSumFormat
    parseEigenstratPrefix = OP.strOption (OP.long "eigenstratOut" <> OP.short 'e' <>
        OP.metavar "<FILE_PREFIX>" <>
        OP.help "Set Eigenstrat as output format. Specify the filenames for the EigenStrat SNP and IND \
        \file outputs: <FILE_PREFIX>.snp.txt and <FILE_PREFIX>.ind.txt \
        \If not set, output will be FreqSum (Default)")
    parseSampleNames = parseSampleNameList <|> parseSampleNameFile
    parseSampleNameList = OP.option (Left . splitOn "," <$> OP.str)
        (OP.long "sampleNames" <> OP.metavar "NAME1,NAME2,..." <>
        OP.help "give the names of the samples as comma-separated list")
    parseSampleNameFile = OP.option (Right <$> OP.str) (OP.long "sampleNameFile" <> OP.metavar "<FILE>" <>
        OP.help "give the names of the samples in a file with one name per \
        \line")
    parseSamplePopName = OP.strOption (OP.long "samplePopName" <> OP.value "Unknown" <> OP.showDefault <>
        OP.metavar "POP" <>
        OP.help "specify the population name of the samples, which is included\
        \ in the output *.ind.txt file. This will be ignored if the output \
        \format is not Eigenstrat")
