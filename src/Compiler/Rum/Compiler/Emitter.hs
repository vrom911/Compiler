{-# LANGUAGE LambdaCase #-}

module Compiler.Rum.Compiler.Emitter where

import           Control.Monad.Except          (ExceptT, forM_, runExceptT, (>=>))
import           Control.Monad.State
import           Data.Char                     (ord)
import           Data.Map                      (Map)
import qualified Data.Map                      as Map (fromList, lookup)
import           Data.Maybe                    (fromMaybe)
import qualified Data.Text                     as T

import Text.Show.Pretty
import qualified LLVM.AST                      as AST (Module (..), Name (..),
                                                       Operand (..), Operand (..),
                                                       Type (..))
import qualified LLVM.AST.Constant             as C (Constant (..))
import qualified LLVM.AST.Type                 as Ty
import           LLVM.Context                  (withContext)
import           LLVM.Module                   (moduleLLVMAssembly, withModuleFromAST)

import           Compiler.Rum.Compiler.CodeGen
import qualified Compiler.Rum.Internal.AST     as Rum

import           Debug.Trace

toSig :: [(Rum.Variable, Rum.DataType)] -> [(AST.Type, AST.Name)]
toSig = let nm = T.unpack . Rum.varName in
        map (\(x, y) -> (fromDataToType y, AST.Name (nm x)))

-- Fun declarations + main body
codeGenAll :: Rum.Program -> LLVM ()
codeGenAll pr = let (funs, main) = span isFunDeclSt pr in
    codeGenTops funs >>= codeGenMain main
  where
    isFunDeclSt :: Rum.Statement -> Bool
    isFunDeclSt Rum.Fun{} = True
    isFunDeclSt _         = False

-- Deal with std funs
codegenProgram :: Rum.Program -> LLVM ()
codegenProgram program = do
    codeGenAll program

    declareExtFun pointer "malloc"      [(Ty.i32, AST.Name "")]  False
    declareExtFun Ty.i32  "rumRead"     [] False
    declareExtFun Ty.i32  "rumWrite"    [(Ty.i32, AST.Name "")]  False
    declareExtFun Ty.i32  "rumWriteStr" [(Ty.i32, AST.Name "")]  False
    declareExtFun Ty.i32  "rumStrlen"   [(pointer, AST.Name "")] False
    declareExtFun Ty.i32  "rumStrget"   [(pointer, AST.Name ""), (Ty.i32, AST.Name "")] False
    declareExtFun Ty.i32  "rumStrcmp"   [(pointer, AST.Name ""), (pointer, AST.Name "")] False
    declareExtFun Ty.i32  "rumArrlen"   [(arrType, AST.Name "")] False
    declareExtFun pointer "rumStrsub"   [(pointer, AST.Name ""), (Ty.i32, AST.Name ""), (Ty.i32, AST.Name "")] False
    declareExtFun pointer "rumStrdup"   [(pointer, AST.Name "")] False
    declareExtFun pointer "rumStrset"   [(pointer, AST.Name ""), (Ty.i32, AST.Name ""), (Ty.i8, AST.Name "")] False
    declareExtFun pointer "rumStrcat"   [(pointer, AST.Name ""), (pointer, AST.Name "")] False
    declareExtFun pointer "rumStrmake"  [(Ty.i32, AST.Name ""),  (Ty.i8, AST.Name "")] False

-- Declaration of many custom funs
codeGenTops :: Rum.Program -> LLVM [(String, Ty.Type)]
codeGenTops x = forM x codeGenTop

-- Deal with one fun declaration in the beginning of the file
codeGenTop :: Rum.Statement -> LLVM (String, Ty.Type)
codeGenTop Rum.Fun{..} = do
    let fnm   = Rum.varName funName
    let retTp = fromDataToType retType
    defineFun retTp fnm fnargs bls
    pure (T.unpack fnm, retTp)
  where
    p      = map fst params
    fnargs = toSig params
    bls    = createBlocks $ execCodegen $ do
        entr <- addBlock entryBlockName
        setBlock entr
        forM_ params $ \(a, b) -> do
            let aName = T.unpack $ Rum.varName a
            let t     = fromDataToType b
            var <- alloca t
            () <$ store var (local t (AST.Name aName))
            assign aName var
        codeGenFunProg funBody >>= ret
codeGenTop _ = error "Impossible happened in CodeGenTop. Only fun Declarations allowed!"

-- Deal with stmts after all fun declarations (main)
codeGenMain :: Rum.Program -> [(String, Ty.Type)] -> LLVM ()
codeGenMain pr globalFuns = defineFun iType "main" [] bls
  where
    bls = createBlocks $ execCodegen $ do
        entr <- addBlock "main"
        setBlock entr
        modify (\s -> s {funRetTypes = Map.fromList globalFuns})
        codeGenProg pr
        ret iZero

-- This one is for Fun declarations (should have return value)
codeGenFunProg :: Rum.Program -> Codegen AST.Operand
codeGenFunProg []                 = pure iZero
codeGenFunProg (Rum.Return{..}:_) = cgenExpr retExp
codeGenFunProg (s:stmts)          = codeGenStmt s >> codeGenFunProg stmts

-- Main prog
codeGenProg :: Rum.Program -> Codegen ()
codeGenProg []                 = pure ()
codeGenProg (Rum.Return{..}:_) = cgenExpr retExp >>= ret >> pure ()
codeGenProg (s:stmts)          = codeGenStmt s >> codeGenProg stmts

-- Statements
codeGenStmt :: Rum.Statement -> Codegen ()
codeGenStmt Rum.Skip = return ()
codeGenStmt Rum.Return{..} = cgenExpr retExp >>= ret >> return ()
codeGenStmt Rum.AssignmentVar{..} = do
    cgenedVal <- cgenExpr value
    symTabl   <- gets symTable
    let vars  = map fst symTabl
    let vName = T.unpack $ Rum.varName var
    if vName `elem` vars            -- reassign var
    then do
        oldV <- getVar vName
        store oldV cgenedVal
    else do
        v <- alloca (typeOfOperand cgenedVal)
--        traceM $ "val: " ++ vName ++ "   " ++ show (typeOfOperand cgenedVal)
--        traceM $ "v: " ++ vName ++ "   " ++ show v
--        traceM $ "type v: " ++ vName ++ "   " ++ show (typeOfOperand v)
        store v cgenedVal
        assign vName v
codeGenStmt (Rum.AssignmentArr cell@Rum.ArrCell{..} val) = do
    cgenedVal <- cgenExpr val
    cgenedCell<- cgenCell cell
    () <$ store cgenedCell cgenedVal

codeGenStmt (Rum.FunCallStmt f) =
    void $ codeGenFunCall f
codeGenStmt Rum.IfElse{..} = do
    ifTrueBlock <- addBlock "if.then"
    elseBlock   <- addBlock "if.else"
    ifExitBlock <- addBlock "if.exit"
    -- %entry
    cond <- cgenExpr ifCond
    test <- isTrue cond
    cbr test ifTrueBlock elseBlock -- Branch based on the condition
    -- if.then
    setBlock ifTrueBlock
    codeGenProg trueAct       -- Generate code for the true branch
    br ifExitBlock              -- Branch to the merge block
    -- if.else
    setBlock elseBlock
    codeGenProg falseAct       -- Generate code for the false branch
    br ifExitBlock              -- Branch to the merge block
    -- if.exit
    setBlock ifExitBlock
    return ()
codeGenStmt Rum.RepeatUntil{..} = do
    repeatBlock <- addBlock "repeat.loop"
    condBlock   <- addBlock "repeat.cond"
    exitBlock   <- addBlock "repeat.exit"

    br repeatBlock
    -- repeat-body
    setBlock repeatBlock
    codeGenProg act
    br condBlock
    -- repeat-cond
    setBlock condBlock
    cond <- cgenExpr repCond
    test <- isFalse cond
    cbr test repeatBlock exitBlock
    -- exit block
    setBlock exitBlock
    return ()
codeGenStmt Rum.WhileDo{..} = do
    condBlock  <- addBlock "while.cond"
    whileBlock <- addBlock "while.loop"
    exitBlock  <- addBlock "while.exit"

    br condBlock
    -- while-cond
    setBlock condBlock
    cond <- cgenExpr whileCond
    test <- isTrue cond
    cbr test whileBlock exitBlock
    -- while-true
    setBlock whileBlock
    codeGenProg act
    br condBlock
    -- Exit block
    setBlock exitBlock
    return ()
codeGenStmt Rum.For{..} = do
    startBlock    <- addBlock "for.start"
    condBlock     <- addBlock "for.cond"
    doUpdateBlock <- addBlock "for.loop"
    exitBlock     <- addBlock "for.end"

    br startBlock
    -- Starting point
    setBlock startBlock
    codeGenProg start
    br condBlock
    -- Condition block
    setBlock condBlock
    cond <- cgenExpr expr
    test <- isTrue cond
    cbr test doUpdateBlock exitBlock
    -- for Body + Update block
    setBlock doUpdateBlock
    codeGenProg body >> codeGenProg update
    br condBlock
    -- Exit block
    setBlock exitBlock
    return ()

binOps :: Map Rum.BinOp (AST.Operand -> AST.Operand -> Codegen AST.Operand)
binOps = Map.fromList [ (Rum.Add, iAdd)
                      , (Rum.Sub, iSub)
                      , (Rum.Mul, iMul)
                      , (Rum.Div, iDiv)
                      , (Rum.Mod, iMod)
                      ]

logicOps :: Map Rum.LogicOp (AST.Operand -> AST.Operand -> Codegen AST.Operand)
logicOps = Map.fromList [ (Rum.And, lAnd)
                        , (Rum.Or, lOr)
                        ]

compOps :: Map Rum.CompOp (AST.Operand -> AST.Operand -> Codegen AST.Operand)
compOps = Map.fromList [ (Rum.Eq, iEq)
                       , (Rum.NotEq, iNeq)
                       , (Rum.Lt, iLt)
                       , (Rum.Gt, iGt)
                       , (Rum.NotGt, iNotGt)
                       , (Rum.NotLt, iNotLt)
                       ]

{-# ANN cgenExpr ("HLint: ignore Use uncurry" :: String) #-}
cgenExpr :: Rum.Expression -> Codegen AST.Operand
cgenExpr (Rum.Const (Rum.Number c)) = pure $ cons $ C.Int iBits (fromIntegral c)
cgenExpr (Rum.Const (Rum.Ch c))     = pure $ cons $ C.Int 8 (fromIntegral $ ord c)
cgenExpr (Rum.Const (Rum.Str s))    = pure $ cons $ C.Array Ty.i8 $
                                        map (C.Int 8 . fromIntegral . ord) (T.unpack s) ++ [C.Int 8 0]
cgenExpr (Rum.ArrC cell) = cgenCell cell
cgenExpr (Rum.ArrLit exps) = do
  let len = length exps
  cgenedE <- mapM cgenExpr exps
  let elemType = Ty.ptr $ typeOfOperand $ head cgenedE
  tempArr <- alloca elemType
  memoryArr <- codeGenFunCall $ Rum.FunCall "malloc" [Rum.Const $ Rum.Number len]
  memoryBit <- bitcast memoryArr elemType
  store tempArr memoryBit
  forM_ (zip [0..] cgenedE) $ \(i, e) ->
    storeArrIdx tempArr i e
  structure <- alloca $ Ty.StructureType False [elemType, Ty.i32]
  arrLen <- getElementPtrLen structure
  store arrLen $ cons $ C.Int iBits (fromIntegral len)
  arrData <- getElementPtrType structure elemType
  store arrData memoryBit
--  pure $ cons $ C.Struct Nothing False [C.Array Ty.i32 [], C.Int iBits (fromIntegral len)]
  load structure
cgenExpr (Rum.Var x) = let nm = T.unpack $ Rum.varName x in
    getVar nm >>= \v ->
        gets varTypes >>= \tps -> case Map.lookup nm tps of
            Just Ty.StructureType{}   -> pure v
            Just _                    -> load v
            Nothing                   -> error "variable type is unknown"
cgenExpr (Rum.Neg e) = cgenExpr e >>= iSub iZero
cgenExpr Rum.BinOper{..} =
    case Map.lookup bop binOps of
        Just f  -> cgenExpr l >>= \x -> cgenExpr r >>= \y -> f x y
        Nothing -> error "No such binary operator"
cgenExpr Rum.LogicOper{..} =
    case Map.lookup lop logicOps of
        Just f  -> cgenExpr l >>= \x -> cgenExpr r >>= \y -> f x y
        Nothing -> error "No such logic operator"
cgenExpr Rum.CompOper{..} =
    case Map.lookup cop compOps of
        Just f  -> cgenExpr l >>= \x -> cgenExpr r >>= \y -> f x y
        Nothing -> error "No such logic operator"
cgenExpr (Rum.FunCallExp f) = codeGenFunCall f


rumFunNamesMap :: Map String (String, Ty.Type)
rumFunNamesMap = Map.fromList [ ("write",    ("rumWrite",    iType))
                              , ("read",     ("rumRead",     iType))
                              , ("strlen",   ("rumStrlen",   iType))
                              , ("strget",   ("rumStrget",   iType))
                              , ("strsub",   ("rumStrsub",   Ty.ptr Ty.i8))
                              , ("strdup",   ("rumStrdup",   Ty.ptr Ty.i8))
                              , ("strset",   ("rumStrset",   Ty.ptr Ty.i8))
                              , ("strcat",   ("rumStrcat",   Ty.ptr Ty.i8))
                              , ("strcmp",   ("rumStrcmp",   iType))
                              , ("writeStr", ("rumWriteStr", iType))
                              , ("strmake",  ("rumStrmake",  Ty.ptr Ty.i8))
                              , ("arrmake",  ("rumarrmake",  Ty.ptr Ty.i8))
                              , ("Arrmake",  ("rumArrmake",  Ty.ptr Ty.i8))
                              , ("arrlen",   ("rumArrlen",   iType))
                              , ("malloc",   ("malloc",      Ty.ptr Ty.i8))
                              ]

codeGenFunCall :: Rum.FunCall -> Codegen AST.Operand
codeGenFunCall Rum.FunCall{..} =
    let funNm = T.unpack $ Rum.varName fName in
    mapM modifiedCgenExpr args >>= \largs ->
--    traceShow largs $
    case funNm of
    "arrlen" ->
        case largs of
            [v@(AST.ConstantOperand (C.Struct _ _ [_, x]))] -> pure (cons x)
            [v@(AST.LocalReference Ty.StructureType{..} _)] ->
--                traceShow v $
                getElementPtrLen v >>= load
            x -> error ("Wrong arrlen argument" ++ show x)
    "arrmake" ->
            case largs of
                [AST.ConstantOperand (C.Int _ n), x@(AST.ConstantOperand cx)] ->
--                    alloca iType >>= \m -> store m (AST.ConstantOperand $ C.Array iType $ replicate (fromIntegral n) cx) >>= \res ->
                    pure $ cons $ C.Struct Nothing False
                    [C.GetElementPtr True (C.Array iType $ replicate (fromIntegral n) cx) [], cx]

    _ ->
        case Map.lookup funNm rumFunNamesMap of
            Just (n, t) -> call (externf t (AST.Name n)) largs
            Nothing     -> gets funRetTypes >>= \globalFuns ->
                call (externf (funType globalFuns) (AST.Name funNm)) largs
                where
                    funType globalFuns = fromMaybe (error "Function is not in scope") (Map.lookup funNm globalFuns)

modifiedCgenExpr :: Rum.Expression -> Codegen AST.Operand
modifiedCgenExpr str@(Rum.Const (Rum.Str _)) = do
    codeGenStmt (Rum.AssignmentVar "T@" str)
    getVar "T@" >>= getElementPtr
modifiedCgenExpr x = cgenExpr x

cgenCell Rum.ArrCell{..} = let nm = T.unpack $ Rum.varName arr in
    mapM cgenExpr index >>= \inds -> getVar nm
        >>= \v -> getToCell v (map foldEx inds)
  where
    getToCell :: AST.Operand -> [Integer] ->Codegen AST.Operand
    getToCell o [] = load o
    getToCell v@(AST.LocalReference Ty.StructureType{..} _) (x:xs) =
--      getElementPtrType v (head elementTypes) >>= \op ->
--      getElementPtrIndType op (getChildType op) x >>= \op1 ->
      getElementPtr v >>= load >>= \v' ->
        getElementPtrArr v' x >>= \op1 ->
          getToCell op1 xs
--    getToCell o (x:xs) = getElementPtrInd o x >>= \op -> getToCell op xs

    foldEx :: AST.Operand -> Integer
    foldEx (AST.ConstantOperand (C.Int 32 x)) = x
    foldEx (AST.LocalReference t n) = undefined
    foldEx x = 0

    getChildType :: AST.Operand -> Ty.Type
    getChildType (AST.LocalReference Ty.StructureType{..} _) = head elementTypes
    getChildType (AST.LocalReference Ty.ArrayType{..} _)     = elementType

-------------------------------------------------------------------------------
-- Compilation
-------------------------------------------------------------------------------
liftError :: ExceptT String IO a -> IO a
liftError = runExceptT >=> either fail return

codeGenMaybeWorks :: String -> Rum.Program -> IO AST.Module
codeGenMaybeWorks moduleName program = do
  putStrLn "BEFORE"
  pPrint llvmAST
  putStrLn "AFTER"
  withContext $ \context ->
    liftError $ withModuleFromAST context llvmAST $ \m -> do
      putStrLn "INSIDE"
      llstr <- moduleLLVMAssembly m
      writeFile "local_example.ll" llstr
      return llvmAST
  where
    llvmModule    = emptyModule moduleName
    generatedLLVM = codegenProgram program
    llvmAST       = runLLVM llvmModule generatedLLVM
