module Rum.Internal.ToString
       ( progToStr
       ) where

import Relude.Extra.Enum (next)

import Rum.Internal.AST (ArrCell (..), BinOp (..), CompOp (..), Expression (..), FunCall (..),
                         LogicOp (..), Program, RumType (..), Statement (..), Variable (..))

import qualified Data.Text as T


tab :: Int -> Text
tab n = T.cons '\n' (T.replicate (2*n) " ")

progToStr :: Int -> Program -> Text
progToStr _ []         = ""
progToStr n [x]        = stmtToStr n x
progToStr n (x1:x2:xs) = stmtToStr n x1 <> ";" <> progToStr n (x2:xs)


stmtToStr :: Int -> Statement -> Text
stmtToStr n AssignmentVar{..}  = tab n <> varName var <> " := " <> exprToStr value
stmtToStr n AssignmentArr{..}  = tab n <> arrCellToStr arrC <> " := " <> exprToStr value
stmtToStr n Skip            = tab n <> "skip "
stmtToStr n IfElse{..}      = tab n <> "if"   <> tab (next n) <> exprToStr ifCond <>
                              tab n <> "then" <> progToStr (next n) trueAct <>
                              tab n <> "else" <> progToStr (next n) falseAct <>
                              tab n <> "fi"
stmtToStr n RepeatUntil{..} = tab n <> "repeat" <> progToStr (next n) act <>
                              tab n <> "until " <> exprToStr repCond
stmtToStr n WhileDo{..}     = tab n <> "while " <> exprToStr whileCond <>
                              tab n <> "do"     <> progToStr (next n) act <>
                              tab n <> "od"
stmtToStr n For{..}         = tab n <> "for " <> progToStr (next n) start <>
                                       ", "   <> tab (next n) <> exprToStr expr <>
                                       ", "   <> progToStr (next n) update <>
                              tab n <> "do"   <> progToStr (next n) body <>
                              tab n <> "od"

stmtToStr n Fun{..}         = tab n <> "fun " <> varName funName <> "(" <> expListStr (Var <$> params) <> ") begin" <>
                              progToStr (next n) funBody <>
                              tab n <> "end"
stmtToStr n Return{..}      = tab n <> "return " <> exprToStr retExp
stmtToStr n (FunCallStmt f) = tab n <> funCallToStr f

exprToStr :: Expression -> Text
exprToStr (ConstExp c)   = typeToStr c
exprToStr (ArrC arC)     = arrCellToStr arC
exprToStr (ArrLit lits)  = "[" <> expListStr lits <> "]"
exprToStr (Var v)        = varName v
exprToStr (Neg e)        = "-(" <> exprToStr e <> ")"
exprToStr BinOper{..}    = paren l <> bToStr bop <> paren r
exprToStr LogicOper{..}  = paren l <> lToStr lop <> paren r
exprToStr CompOper{..}   = paren l <> cToStr cop <> paren r
exprToStr (FunCallExp f)=funCallToStr f

arrCellToStr :: ArrCell -> Text
arrCellToStr ArrCell{..} =  varName arr <> T.concat (map (\i -> "[" <> exprToStr i <> "]") index)

funCallToStr :: FunCall -> Text
funCallToStr FunCall{..}   = varName fName <> "(" <> expListStr args <> ")"

typeToStr :: RumType -> Text
typeToStr (Number n) = show n
typeToStr (Ch c)     = show c
typeToStr (Str s)    = s
typeToStr (Arr a)    = "[" <> T.intercalate ", " (map typeToStr a) <> "]"
typeToStr Unit       = "()"

expListStr :: [Expression] -> Text
expListStr []         = ""
expListStr [x]        = exprToStr x
expListStr (x1:x2:xs) = exprToStr x1 <> ", " <> expListStr (x2:xs)

paren :: Expression -> Text
paren e@(ConstExp _) = exprToStr e
paren e@(Var _)      = exprToStr e
paren x              = "(" <> exprToStr x <> ")"

bToStr :: BinOp -> Text
bToStr Add = " + "
bToStr Sub = " - "
bToStr Mul = " * "
bToStr Div = " / "
bToStr Mod = " % "
bToStr Pow = " ^ "

cToStr :: CompOp -> Text
cToStr Eq    = " == "
cToStr NotEq = " != "
cToStr Lt    = " < "
cToStr NotGt = " <= "
cToStr Gt    = " > "
cToStr NotLt = " >= "

lToStr :: LogicOp -> Text
lToStr And = " && "
lToStr Or  = " || "
lToStr Xor = " !! "
