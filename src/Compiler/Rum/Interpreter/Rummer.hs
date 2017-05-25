module Compiler.Rum.Interpreter.Rummer where

import           Control.Applicative       (liftA2, empty)
import           Control.Monad.State       (get, gets, lift, modify, MonadState)
import           Data.List                 (foldl')
import qualified Data.HashMap.Strict as HM (fromList, union)

import           Compiler.Rum.Internal.AST
import           Compiler.Rum.Internal.Util
import           Compiler.Rum.Interpreter.Rumlude (preludeLibrary)

interpret :: Program -> InterpretT
interpret [] = return Unit
interpret (st:stmts) = do
    stRes <- interpretSt st
    x <- gets isReturn
    if x then return stRes else interpret stmts

interpretSt :: Statement -> InterpretT
interpretSt AssignmentVar{..}  = eval value >>= \x -> modifyT (updateVars var x)
interpretSt AssignmentArr{..}  = eval value >>= \x -> mapM eval (index arrC)
                                            >>= \inds -> modifyT (updateArrs (arr arrC) inds x)
interpretSt Skip               = return Unit
interpretSt IfElse{..}         = eval ifCond >>= \x ->
    if isFalse x then interpret falseAct else interpret trueAct
interpretSt st@WhileDo{..}     = do
    c <- eval whileCond
    whenT (isTrue c) $ interpret act >> interpretSt st
interpretSt st@RepeatUntil{..} = do
    () <$ interpret act
    c <- eval repCond
    whenT (isFalse c) $ interpretSt st
interpretSt For{..} = interpret start *> forDo
  where
    forDo = do
        c <- eval expr
        whenT (isTrue c) $ interpret body >> interpret update >> forDo
interpretSt Fun{..} = modifyT (updateFuns funName params $ \_ -> interpret funBody)
interpretSt Return{..} = modify (updateBool True) >> eval retExp
interpretSt (FunCallStmt f) = evalFunCall f

{-
 StateT s (MaybeT IO) a = s -> IO (Maybe (a, s))
 MaybeT IO a = IO (Maybe a)
 pure x :: a -> m a = a -> StateT s (MaybeT IO) a = a -> (s -> IO (Maybe (a, s))
 empty :: StateT s (MaybeT IO) a = s -> IO Nothing
-}
eval :: Expression -> InterpretT
eval (Const c)     = pure c
eval (Var v)       = do
    var <- gets (findVar v)
    -- maybe empty pure var
    case var of
        Nothing -> empty
        Just x  -> pure x
eval (ArrC ArrCell{..}) = do
    inds <- mapM eval index
    Just var <- gets (findVar arr)
    return $ foldl' (\(Arr a) (Number i) -> a !! i) var inds
eval (ArrLit exps) = Arr <$> mapM eval exps
eval (Neg e)       = do
    Number x <- eval e
    pure $ Number (negate x)
eval BinOper {..} = do
    Number left <- eval l
    Number right <- eval r
    pure $ Number (binOp bop left right)
eval LogicOper{..} = do
    Number left <- eval l
    Number right <- eval r
    pure $ Number (logicOp lop left right)
eval CompOper{..}  = liftA2 (intCompare cop) (eval l) (eval r)
eval (FunCallExp f) = evalFunCall f


evalFunCall :: FunCall -> InterpretT
evalFunCall FunCall{..} = do
    env <- get
    let funs    = funEnv env
    let globals = varEnv env
    evalArgs          <- mapM eval args
    Just (names, fun) <- gets (findFun fName)
    let locals = HM.fromList (zip names evalArgs)
    Interpret $ lift $ evalRunInterpret (fun evalArgs) (Env (locals `HM.union` globals) funs False)

--------------
---- Util ----
--------------
whenT :: (Applicative f) => Bool -> f Type -> f Type
whenT cond s  = if cond then s else pure Unit

modifyT :: MonadState s m => (s -> s) -> m Type
modifyT f = modify f >> pure Unit

-------------------
----- Rummer ------
-------------------
rumInterpreter :: [Statement] -> IO ()
rumInterpreter p = runIOInterpret (interpret p) (Env mempty preludeLibrary False)
