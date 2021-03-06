module HipSpec.Literal (trLiteral) where

import HipSpec.Theory
import HipSpec.Translate
import HipSpec.Property

import HipSpec.Lang.PolyFOL
import HipSpec.Id

trLiteral :: ArityMap -> [Id] -> Literal -> Formula LogicId LogicId
trLiteral am sc (e1 :=: e2) = trSimpExpr am sc e1 === trSimpExpr am sc e2

