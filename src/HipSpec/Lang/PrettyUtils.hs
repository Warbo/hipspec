{-# LANGUAGE OverloadedStrings #-}
module HipSpec.Lang.PrettyUtils where

import Text.PrettyPrint

infix 1 $\

($\) :: Doc -> Doc -> Doc
d1 $\ d2 = hang d1 2 d2

data Types = Show | Don'tShow

ppTyped :: Types -> Doc -> Doc -> Doc
ppTyped Show e t = e <+> "::" $\ t
ppTyped _    e _ = e

-- | Pretty printing kit.
type P a = a -> Doc

parensIf :: Bool -> Doc -> Doc
parensIf True  = parens
parensIf False = id

csv :: [Doc] -> Doc
csv = inside "(" "," ")"

inside :: Doc -> Doc -> Doc -> [Doc] -> Doc
inside _ _ _ []     = empty
inside l p r (x:xs) = cat (go (l <> x) xs)
  where
    go y []     = [y,r]
    go y (z:zs) = y : go (p <> z) zs

