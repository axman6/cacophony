{-# LANGUAGE RankNTypes, ScopedTypeVariables #-}
----------------------------------------------------------------
-- |
-- Module      : Crypto.Noise.Internal.Handshake.Interpreter
-- Maintainer  : John Galt <jgalt@centromere.net>
-- Stability   : experimental
-- Portability : POSIX
module Crypto.Noise.Internal.Handshake.Interpreter where

import Control.Applicative.Free
import Control.Exception.Safe
import Control.Lens
import Control.Monad.Coroutine.SuspensionFunctors
import Data.ByteArray (splitAt)
import Data.Monoid    ((<>))
import Data.Proxy
import Prelude hiding (splitAt)

import Crypto.Noise.Cipher
import Crypto.Noise.DH
import Crypto.Noise.Hash
import Crypto.Noise.Internal.Handshake.Pattern hiding (e, s, ee, es, se, ss)
import Crypto.Noise.Internal.Handshake.State
import Crypto.Noise.Internal.SymmetricState
import Crypto.Noise.Internal.Types

interpretToken :: forall c d h r. (Cipher c, DH d, Hash h)
               => HandshakeRole
               -> Token r
               -> Handshake c d h r
interpretToken opRole (E next) = do
  myRole <- use $ hsOpts . hoRole

  if opRole == myRole then do
    (_, pk) <- getKeyPair hoLocalEphemeral "local ephemeral"
    let pkBytes = dhPubToBytes pk
    hsSymmetricState %= mixHash pkBytes
    hsMsgBuffer      <>= pkBytes

  else do
    buf <- use hsMsgBuffer
    let (pkBytes, remainingBytes) = splitAt (dhLength (Proxy :: Proxy d)) buf
    theirKey <- maybe (throwM . HandshakeError $ "invalid remote ephemeral key")
                      return
                      (dhBytesToPub pkBytes)
    hsOpts . hoRemoteEphemeral .= Just theirKey
    hsSymmetricState           %= mixHash pkBytes
    hsMsgBuffer                .= remainingBytes

  return next
interpretToken _ (S  next) = return next
interpretToken _ (Ee next) = return next
interpretToken _ (Es next) = return next
interpretToken _ (Se next) = return next
interpretToken _ (Ss next) = return next

processMsgPattern :: (Cipher c, DH d, Hash h)
                  => HandshakeRole
                  -> MessagePattern r
                  -> Handshake c d h r
processMsgPattern opRole mp = do
  myRole <- use $ hsOpts . hoRole
  buf    <- use hsMsgBuffer
  input  <- Handshake <$> request $ buf

  if opRole == myRole then do
    hsMsgBuffer .= mempty
    r <- runAp (interpretToken opRole) mp
    ss <- use hsSymmetricState
    (encPayload, ss') <- encryptAndHash input ss
    hsMsgBuffer      <>= cipherTextToBytes encPayload
    hsSymmetricState .= ss'
    return r

  else do
    hsMsgBuffer .= input
    r <- runAp (interpretToken opRole) mp
    remaining <- use hsMsgBuffer
    ss <- use hsSymmetricState
    (decPayload, ss') <- decryptAndHash (cipherBytesToText remaining) ss
    hsMsgBuffer .= decPayload
    hsSymmetricState .= ss'
    return r

interpretMessage :: (Cipher c, DH d, Hash h)
                 => Message r
                 -> Handshake c d h r
interpretMessage (PreInitiator _  next) = return next
interpretMessage (PreResponder _  next) = return next
interpretMessage (Initiator mp next) = processMsgPattern InitiatorRole mp >> return next
interpretMessage (Responder mp next) = processMsgPattern ResponderRole mp >> return next

runHandshakePattern :: (Cipher c, DH d, Hash h)
                    => HandshakePattern
                    -> Handshake c d h ()
runHandshakePattern hp = runAp interpretMessage $ hp ^. hpMsgSeq

getPublicKey :: Lens' (HandshakeOpts d) (Maybe (PublicKey d))
             -> String
             -> Handshake c d h (PublicKey d)
getPublicKey k desc = do
  r <- use $ hsOpts . k
  maybe (throwM (InvalidHandshakeOptions $ "a " <> desc <> " key is required but has not been set"))
        return
        r

getKeyPair :: Lens' (HandshakeOpts d) (Maybe (KeyPair d))
           -> String
           -> Handshake c d h (KeyPair d)
getKeyPair k desc = do
  r <- use $ hsOpts . k
  maybe (throwM (InvalidHandshakeOptions $ "a " <> desc <> " key is required but has not been set"))
        return
        r
