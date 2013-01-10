{-# LANGUAGE TemplateHaskell #-}
{-

   Compile with -fforce-recomp -fexpose-all-unfoldings -fno-ignore-interface-pragmas -fno-omit-interface-pragmas

-}
module Main where

import HipSpec.Prelude
import HipSpec
import Prelude(Bool(..), IO, undefined)
import Properties
import Definitions


main :: IO ()
main = hipSpec $(fileName)
    [ vars ["x", "y", "z"] (undefined :: Nat)
    , vars ["xs", "ys", "zs"] (undefined :: [A])
    -- Constructors
    , "[]"     `fun0` ([] :: [A])
    , ":"      `fun2` ((:) :: A -> [A] -> [A])
    , "Z"      `fun0` Z
    , "S"      `fun1` S
    -- Functions
    , "length" `fun1`  (length :: [A] -> Nat)
    , "qrev"   `fun2`  (qrev   :: [A] -> [A] -> [A])
    , "+"      `fun2`  (+)
    ]

-- The properties needs to be mentioned here to be included
to_show = prop_T07
