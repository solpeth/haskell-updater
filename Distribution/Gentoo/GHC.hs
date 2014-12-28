{-# LANGUAGE CPP #-}
{- |
   Module      : Distribution.Gentoo.GHC
   Description : Find GHC-related breakages on Gentoo.
   Copyright   : (c) Ivan Lazar Miljenovic 2009
   License     : GPL-2 or later

   This module defines helper functions to find broken packages in
   GHC, or else find packages installed with older versions of GHC.
 -}
module Distribution.Gentoo.GHC
       ( ghcVersion
       , ghcLoc
       , ghcLibDir
       , oldGhcPkgs
       , brokenPkgs
       , allInstalledPackages
       ) where

import Distribution.Gentoo.Util
import Distribution.Gentoo.Packages

-- Cabal imports
import Distribution.Simple.Utils(rawSystemStdInOut)
import Distribution.Verbosity(silent)
import Distribution.Package(PackageIdentifier, packageId)
import Distribution.InstalledPackageInfo(InstalledPackageInfo_)
import Distribution.Text(display)

-- Other imports
import Data.Char(isDigit)
import Data.Either(partitionEithers)
import Data.Maybe(fromJust)
import qualified Data.Map as Map
import Data.Map(Map)
import qualified Data.ByteString.Char8 as BS
import System.FilePath((</>), takeExtension, pathSeparator)
import System.Directory( canonicalizePath
                       , doesDirectoryExist
                       , findExecutable)
import Control.Monad(foldM, liftM)

import Output

-- -----------------------------------------------------------------------------

-- Common helper utils, etc.

-- Get only the first line of output
rawSysStdOutLine     :: FilePath -> [String] -> IO String
rawSysStdOutLine app = liftM (head . lines) . rawCommand app

rawCommand          :: FilePath -> [String] -> IO String
rawCommand cmd args = do (out,_,_) <- rawSystemStdInOut silent  -- verbosity
                                                        cmd     -- program loc
                                                        args    -- args
#if MIN_VERSION_Cabal(1,18,0)
                                                        Nothing -- cabal-1.18+: new working dir
                                                        Nothing -- cabal-1.18+: new environment
#endif /* MIN_VERSION_Cabal(1,18,0) */
                                                        Nothing -- input text and binary mode
                                                        False   -- is output in binary mode
                         return out

-- Get the first line of output from calling GHC with the given
-- arguments.
ghcRawOut      :: [String] -> IO String
ghcRawOut args = ghcLoc >>= flip rawSysStdOutLine args

-- Cheat with using fromJust since we know that GHC must be in $PATH
-- somewhere, probably /usr/bin.
ghcLoc :: IO FilePath
ghcLoc = liftM fromJust $ findExecutable "ghc"

-- The version of GHC installed.
ghcVersion :: IO String
ghcVersion = liftM (dropWhile (not . isDigit)) $ ghcRawOut ["--version"]

-- The directory where GHC has all its libraries, etc.
ghcLibDir :: IO FilePath
ghcLibDir = canonicalizePath =<< ghcRawOut ["--print-libdir"]

ghcPkgRawOut      :: [String] -> IO String
ghcPkgRawOut args = ghcPkgLoc >>= flip rawCommand args

-- Cheat with using fromJust since we know that ghc-pkg must be in $PATH
-- somewhere, probably /usr/bin.
ghcPkgLoc :: IO FilePath
ghcPkgLoc = liftM fromJust $ findExecutable "ghc-pkg"

-- Return the Gentoo .conf files found in this GHC libdir
confFiles     :: FilePath -> IO [FilePath]
confFiles dir = do let gDir = dir </> "gentoo"
                   exists <- doesDirectoryExist gDir
                   if exists
                     then do conts <- getDirectoryContents' gDir
                             return $ map (gDir </>)
                               $ filter isConf conts
                     else return []
  where
    isConf file = takeExtension file == ".conf"

tryMaybe     :: (a -> Maybe b) -> a -> Either a b
tryMaybe f a = maybe (Left a) Right $ f a

type CabalPV = String -- serialized 'PackageIdentifier'
type ConfMap = Map CabalPV FilePath

-- Attempt to match the provided broken package to one of the
-- installed packages.
matchConf :: ConfMap -> CabalPV -> Either CabalPV FilePath
matchConf = tryMaybe . flip Map.lookup

-- Read in all Gentoo .conf files from the current GHC version and
-- create a Map
readConf :: Verbosity -> IO ConfMap
readConf v = ghcLibDir >>= confFiles >>= foldM (addConf v) Map.empty

-- cabal package text format
-- "[InstalledPackageInfo {installedPackageId = Insta..."
parse_as_cabal_package :: String -> Maybe CabalPV
parse_as_cabal_package cont =
    case reads cont of
        []       -> Nothing
        -- ebuilds that have CABAL_CORE_LIB_GHC_PV set
        -- for this version of GHC will have a .conf
        -- file containing just []
        [([],_)] -> Nothing
        rd       -> Just $ display $ cfNm rd
  where
    -- It's not InstalledPackageInfo, as it can't read the modules
    cfNm :: [([InstalledPackageInfo_ String], String)] -> PackageIdentifier
    cfNm = packageId . head . fst . head

-- ghc package text format
-- "name: zlib-conduit\n
--  version: 1.1.0\n
--  id: zlib-condui..."
parse_as_ghc_package :: BS.ByteString -> Maybe CabalPV
parse_as_ghc_package cont =
    case (map BS.words . BS.lines) cont of
        ( [name_key, bn] : [ver_key, bv] : _)
            | name_key == BS.pack "name:" && ver_key == BS.pack "version:"
            -> Just $ BS.unpack bn ++ "-" ++ BS.unpack bv
        _   -> Nothing

-- Add this .conf file to the Map
addConf :: Verbosity -> ConfMap -> FilePath -> IO ConfMap
addConf v cmp conf = do
    cont <- BS.readFile conf
    case ( parse_as_ghc_package cont
         , parse_as_cabal_package (BS.unpack cont)
         ) of
        (Just dn, _) -> return $ Map.insert dn conf cmp
        (_, Just dn) -> return $ Map.insert dn conf cmp
        -- empty files are created for
        -- phony packages like CABAL_CORE_LIB_GHC_PV
        -- and binary-only packages.
        _ | BS.null cont
                     -> return cmp
        _            -> do say v $ unwords [ "failed to parse"
                                           , show conf
                                           , ":"
                                           , show (BS.take 30 cont)
                                           ]
                           return cmp

checkPkgs :: Verbosity
             -> ([CabalPV], [FilePath])
             -> IO ([Package],[CabalPV],[FilePath])
checkPkgs _v (pns,cnfs)
  = do pkgs <- haveFiles cnfs
       return (pkgs, pns, [])

-- -----------------------------------------------------------------------------

-- Finding packages installed with other versions of GHC
oldGhcPkgs :: Verbosity -> IO [Package]
oldGhcPkgs v =
    do thisGhc <- ghcLibDir
       vsay v $ "oldGhcPkgs ghc lib: " ++ show thisGhc
       let thisGhc' = BS.pack thisGhc
       -- It would be nice to do this, but we can't assume
       -- some crazy user hasn't deleted one of these dirs
       -- libFronts' <- filterM doesDirectoryExist libFronts
       liftM notGHC $ checkLibDirs v thisGhc' libFronts

-- Find packages installed by other versions of GHC in this possible
-- library directory.
checkLibDirs :: Verbosity -> BSFilePath -> [BSFilePath] -> IO [Package]
checkLibDirs v thisGhc libDirs =
    do vsay v $ "checkLibDir ghc libs: " ++ show (thisGhc, libDirs)
       pkgsHaveContent (hasDirMatching wanted)
  where
    wanted dir = isValid dir && (not . isInvalid) dir

    isValid dir = any (`isGhcLibDir` dir) libDirs

    -- Invalid if it's this GHC
    isInvalid fp = fp == thisGhc || BS.isPrefixOf (thisGhc `BS.snoc` pathSeparator) fp

-- A valid GHC library directory starting at libdir has a name of
-- "ghc", then a hyphen and then a version number.
isGhcLibDir :: BSFilePath -> BSFilePath -> Bool
isGhcLibDir libdir dir = go ghcDirName
  where
    -- This is hacky because FilePath doesn't work on Bytestrings...
    libdir' = BS.snoc libdir pathSeparator
    ghcDirName = BS.pack "ghc"

    go dn = BS.isPrefixOf ghcDir dir
            -- Any possible version starts with a digit
            && isDigit (BS.index dir ghcDirLen)
      where
        ghcDir = flip BS.snoc '-' $ BS.append libdir' dn
        ghcDirLen = BS.length ghcDir


-- The possible places GHC could have installed lib directories
libFronts :: [BSFilePath]
libFronts = map BS.pack
            $ do lib <- ["lib", "lib64"]
                 return $ "/" </> "usr" </> lib

-- -----------------------------------------------------------------------------

-- Finding broken packages in this install of GHC.
brokenPkgs :: Verbosity -> IO ([Package],[CabalPV],[FilePath])
brokenPkgs v = brokenConfs v >>= checkPkgs v

-- .conf files from broken packages of this GHC version
brokenConfs :: Verbosity -> IO ([CabalPV], [FilePath])
brokenConfs v =
    do vsay v "brokenConfs: getting broken output from 'ghc-pkg'"
       brkn <- getBroken
       -- Check if we actually have to go look up files and
       -- do IO.
       vsay v $ "brokenConfs: resolving package names to gentoo equivalents. " ++ show (length brkn) ++ " are broken"
       if null brkn
           then return ([], [])
           else do vsay v "brokenConfs: reading '*.conf' files"
                   cnfs <- readConf v
                   vsay v $ "brokenConfs: got " ++ show (Map.size cnfs) ++ " '*.conf' files"
                   return $ partitionEithers $ map (matchConf cnfs) brkn

-- Return the closure of all packages affected by breakage
-- in format of ["name-version", ... ]
getBroken :: IO [CabalPV]
getBroken = liftM words
            $ ghcPkgRawOut ["check", "--simple-output"]

-- -----------------------------------------------------------------------------

allInstalledPackages :: IO [Package]
allInstalledPackages = do libDir <- ghcLibDir
                          let libDir' = BS.pack libDir
                          liftM notGHC $ pkgsHaveContent
                                       $ hasDirMatching (==libDir')
