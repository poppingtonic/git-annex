{- git-annex webapp gpg stuff
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE QuasiQuotes, TemplateHaskell, OverloadedStrings #-}

module Assistant.WebApp.Gpg where

import Assistant.WebApp.Common
import Assistant.Gpg
import Utility.Gpg
import qualified Git.Command
import qualified Git.Remote
import qualified Annex.Branch
import qualified Git.GCrypt
import Assistant.MakeRemote
import Logs.Remote

import qualified Data.Map as M

gpgKeyDisplay :: KeyId -> Maybe UserId -> Widget
gpgKeyDisplay keyid userid = [whamlet|
  <span title="key id #{keyid}">
    <i .icon-user></i> #
      $maybe name <- userid
        #{name}
      $nothing
        key id #{keyid}
|]

genKeyModal :: Widget
genKeyModal = $(widgetFile "configurators/genkeymodal")

whenGcryptInstalled :: Handler Html -> Handler Html
whenGcryptInstalled a = ifM (liftIO $ inPath "git-remote-gcrypt")
	( a
	, page "Need git-remote-gcrypt" (Just Configuration) $
		$(widgetFile "configurators/needgcrypt")
	)

withNewSecretKey :: (KeyId -> Handler Html) -> Handler Html
withNewSecretKey use = do
	userid <- liftIO $ newUserId
	liftIO $ genSecretKey RSA "" userid maxRecommendedKeySize
	results <- M.keys . M.filter (== userid) <$> liftIO secretKeys
	case results of
		[] -> error "Failed to generate gpg key!"
		(key:_) -> use key

{- Tries to find the name used in remote.log for a gcrypt repository
 - with a given uuid.
 -
 - The gcrypt remote may not be on that is listed in the local remote.log
 - (or the info may be out of date), so this actually fetches the git-annex
 - branch from the gcrypt remote and merges it in, and then looks up
 - the name.
 -}
getGCryptRemoteName :: UUID -> String -> Annex (Maybe Git.Remote.RemoteName)
getGCryptRemoteName u repoloc = do
	tmpremote <- uniqueRemoteName "tmpgcryptremote" 0 <$> gitRepo
	void $ inRepo $ Git.Command.runBool
		[Params "remote add", Param tmpremote, Param $ Git.GCrypt.urlPrefix ++ repoloc]
	mname <- ifM (inRepo $ Git.Command.runBool [Param "fetch", Param tmpremote])
		( do
			void $ Annex.Branch.forceUpdate
			(M.lookup "name" <=< M.lookup u) <$> readRemoteLog
		, return Nothing
		)
	void $ inRepo $ Git.Remote.remove tmpremote
	return mname

checkGCryptRepoEncryption :: String -> Handler Html -> Handler Html -> Handler Html
checkGCryptRepoEncryption location notencrypted encrypted = 
	dispatch =<< liftAnnex (inRepo $ Git.GCrypt.probeRepo location)
  where
	dispatch Git.GCrypt.Decryptable = encrypted
	dispatch Git.GCrypt.NotEncrypted = notencrypted
	dispatch Git.GCrypt.NotDecryptable =
		error "This git repository is encrypted with a GnuPG key that you do not have."
