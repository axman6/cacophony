module Verify where

import Control.Exception    (SomeException)
import Control.Monad        (forM_)
import Data.Aeson           (eitherDecode)
import Data.Bits
import Data.ByteString.Lazy (readFile)
import Data.Maybe           (fromMaybe)
import Data.Text            (Text, pack)
import Data.Text.IO         (putStrLn)
import Prelude hiding       (readFile, putStrLn)
import System.Exit          (exitFailure)

import Crypto.Noise         (ScrubbedBytes)

import Generate
import Types
import VectorFile

data ValidationResult
  = ResultException      [Either SomeException Message]
  | ResultMsgDifference  [Maybe (Message, Message)]
  | ResultHashDifference ScrubbedBytes ScrubbedBytes
  | ResultSuccess

natureOfFailure :: ValidationResult
                -> Text
natureOfFailure (ResultException _)        = "Exception thrown during handshake."
natureOfFailure (ResultMsgDifference _)    = "Given and calculated messages differ."
natureOfFailure (ResultHashDifference _ _) = "Given and calculated handshake hashes differ."
natureOfFailure ResultSuccess              = "Vector passed but should not have."

resultSuccess :: ValidationResult
              -> Bool
resultSuccess ResultSuccess = True
resultSuccess _             = False

compareMsgs :: [Message] -- ^ Given messages
            -> [Message] -- ^ Calculated messages
            -> [Maybe (Message, Message)]
compareMsgs given calc =
  (\(m1, m2) -> if m1 == m2
    then Nothing
    else Just (m1, m2)) <$> zip given calc

verifyVector :: Vector
             -> ValidationResult
verifyVector given =
  either ResultException finalResult rawResults
  where
    cipher = hsCipher . vProtoName $ given
    dh     = hsDH     . vProtoName $ given
    hash   = hsHash   . vProtoName $ given
    rawResults = populateVector cipher dh hash (mPayload <$> vMessages given) given
    finalResult calc =
      let msgComparison  = compareMsgs (vMessages given) (vMessages calc)
          hashComparison = do
            g <- vHash given
            c <- vHash calc
            return (g, c)
      in
        if any (/= Nothing) msgComparison
          then ResultMsgDifference msgComparison
          else case hashComparison of
            Just (g, c) -> if g /= c then ResultHashDifference g c else ResultSuccess
            Nothing     -> ResultSuccess

printMessageComparison :: Message
                       -> Message
                       -> IO ()
printMessageComparison m1 m2 = do
  putStrLn "Message:"
  putStrLn $ "\tGiven payload:\t\t" <> (encodeSB . mPayload) m1
  putStrLn $ "\tGiven ciphertext:\t" <> (encodeSB . mCiphertext) m1
  putStrLn $ "\tCalculated ciphertext:\t" <> (encodeSB . mCiphertext) m2

printMessage :: Message
             -> IO ()
printMessage m = do
  putStrLn "Message:"
  putStrLn $ "\tPayload:\t" <> (encodeSB . mPayload) m
  putStrLn $ "\tCiphertext:\t" <> (encodeSB . mCiphertext) m

printExFailure :: [Either SomeException Message]
               -> IO ()
printExFailure = mapM_ $
  either (\ex -> putStrLn $ "Exception: " <> (pack . show) ex)
         printMessage

printComparisonFailure :: [Maybe (Message, Message)]
                       -> IO ()
printComparisonFailure mms =
  forM_ mms $ maybe (return ()) (uncurry printMessageComparison)

printHashFailure :: ScrubbedBytes
                 -> ScrubbedBytes
                 -> IO ()
printHashFailure given calc = do
  putStrLn $ "Given handshake hash:\t\t" <> encodeSB given
  putStrLn $ "Calculated handshake hash:\t" <> encodeSB calc

verifyVectorFile :: FilePath
                 -> IO ()
verifyVectorFile f = do
  fd <- readFile f

  vf <- case eitherDecode fd of
    Left err -> do
      putStrLn $ "Error decoding " <> pack f <> ": " <> pack err
      exitFailure
    Right r -> return r

  let results  = (\(idx, v) -> (idx, v, verifyVector v)) <$> zip [0..] (vfVectors vf)
      failures = filter (\(_, v, r) ->
                   vFail v `xor` (not . resultSuccess) r)
                   results

  if not (null failures) then do
    putStrLn $ pack f <> ": The following vectors have failed:\n"
    forM_ failures $ \(idx, vector, result) -> do
      putStrLn "================================================================"
      putStrLn $ "Vector number: " <> (pack . show) (idx :: Integer)

      let protoName = (pack . show . vProtoName) vector
      putStrLn $ "Handshake name: " <> fromMaybe protoName (vName vector)
      putStrLn $ "Protocol name: " <> protoName
      putStrLn $ "Should fail?: " <> if vFail vector then "yes" else "no"
      putStrLn $ "Nature of failure: " <> natureOfFailure result
      case result of
        ResultException ems      -> printExFailure ems
        ResultMsgDifference mms  -> printComparisonFailure mms
        ResultHashDifference g c -> printHashFailure g c
        ResultSuccess            -> return ()
      putStrLn ""
    exitFailure
  else putStrLn $ pack f <> ": All vectors passed."
