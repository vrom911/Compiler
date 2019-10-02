{- | This module implements functions that should go to @Rumlude@ — Rum's
standard prelude.
-}

module Rum.Interpreter.Rumlude
       ( preludeLibrary
       ) where

import Rum.Internal.AST (FunEnv, InterpretT, RumType (..), RumludeFunName (..))
import Rum.Internal.Rumlude (runRumlude, writeRumlude)

import qualified Data.HashMap.Strict as HM (fromList)


-----------------------
---- Default Funcs ----
-----------------------

preludeLibrary :: FunEnv
preludeLibrary = HM.fromList
    [ ("read",    ([], readFun))
    , ("write",   ([], writeFun))
    , ("strlen",  ([], interpretRumlude Strlen))
    , ("strget",  ([], interpretRumlude Strget))
    , ("strsub",  ([], interpretRumlude Strsub))
    , ("strdup",  ([], interpretRumlude Strdup))
    , ("strset",  ([], interpretRumlude Strset))
    , ("strcat",  ([], interpretRumlude Strcat))
    , ("strcmp",  ([], interpretRumlude Strcmp))
    , ("strmake", ([], interpretRumlude Strmake))
    , ("arrlen",  ([], interpretRumlude Arrlen))
    , ("arrmake", ([], interpretRumlude Arrmake))
    , ("Arrmake", ([], interpretRumlude Arrmake))
    ]
  where
    readFun :: [RumType] -> InterpretT
    readFun _ = getLine >>= maybe empty (pure . Number) . readMaybe . toString

    writeFun :: [RumType] -> InterpretT
    writeFun [x] = Unit <$ writeRumlude x
    writeFun _   = error "Paste Several arggs to write function"

    ----------------------
    -- String Functions --
    ----------------------
    interpretRumlude :: RumludeFunName -> [RumType] -> InterpretT
    interpretRumlude f = pure . runRumlude f
