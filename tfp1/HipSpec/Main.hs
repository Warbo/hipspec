{-# LANGUAGE RecordWildCards, NamedFieldPuns, DoAndIfThenElse, ViewPatterns, RecordWildCards #-}
module Main where

import Test.QuickSpec.Main (prune)
import Test.QuickSpec.Term (totalGen,Term,Expr,term,funs, Symbol)
import Test.QuickSpec.Equation (Equation(..), equations, TypedEquation(..), eraseEquation)
import Test.QuickSpec.Generate
import Test.QuickSpec.Signature
import Test.QuickSpec.Utils.Typed
-- import Test.QuickSpec.TestTotality
import qualified Test.QuickSpec.Utils.TypeMap as TypeMap
import qualified Test.QuickSpec.TestTree as TestTree

import qualified Test.QuickSpec.Reasoning.NaiveEquationalReasoning as NER
-- import qualified Test.QuickSpec.Reasoning.PartialEquationalReasoning as PER

import HipSpec.Reasoning

import Data.Void

import HipSpec.ThmLib
import HipSpec.Property hiding (Literal(..))
import HipSpec.Sig.QSTerm
import HipSpec.Init
import HipSpec.Monad hiding (equations)
import HipSpec.MainLoop

import HipSpec.Heuristics.Associativity
import HipSpec.Heuristics.CallGraph
import HipSpec.Utils


-- import HipSpec.Trans.DefinitionalEquations
-- import HipSpec.Sig.Map (maybeLookupSym)
-- import HipSpec.Sig.Types

import Prelude hiding (read)

import qualified Data.Map as M

import Data.List
import Data.Maybe
import Data.Ord

import Control.Monad

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as B

import System.Exit (exitSuccess)

main :: IO ()
main = processFile $ \ m_sig_info user_props -> do
    writeMsg FileProcessed

    -- void (runMainLoop NoCC user_props [])

    case m_sig_info of

        Nothing -> void (runMainLoop NoCC user_props [])

        Just (sig_info@SigInfo{..}) -> do

            (eqs,reps,classes) <- runQuickSpec sig_info

            Params{explore_theory,user_stated_first} <- getParams

            let (~+) | user_stated_first = flip (++)
                     | otherwise         = (++)

{-
            if bottoms then do

                let qsconjs = map (some (peqToProp sig_info)) eqs

                (ctx_init,tot_thms,tot_conjs) <- proveTotality sig_info reps

                ctx_with_def <- pruneWithDefEqs sig_info ctx_init

                void $ runMainLoop
                        ctx_with_def
                        (qsconjs ~+ map vacuous user_props ++ map vacuous tot_conjs)
                        (map vacuous tot_thms)

            else do
                        -}

            let qsconjs = map (eqToProp sig_info)
                              (map (some eraseEquation) eqs)

            mapM_ (checkLint . lintProperty) qsconjs

            let ctx_init = NER.initial (maxDepth sig) (symbols sig) reps

{-
            ctx_with_def <- pruneWithDefEqs sig_info ctx_init
-}

            ctx_final <- runMainLoop ctx_init {- ctx_with_def -}
                                     (qsconjs ~+ map vacuous user_props)
                                     []

            when explore_theory $ do
                let pruner   = prune ctx_init (map erase reps) id
                    provable = evalEQR ctx_final . equal
                    explored_theory
                        = filter (not . evalEQR ctx_init {- ctx_with_def -} . equal)
                        $ pruner $ filter provable
                        $ map (some eraseEquation) (equations classes)
                writeMsg $ ExploredTheory $ map (showEquation sig) explored_theory

    Params{json} <- getParams

    case json of
        Just json_file -> do
            msgs <- getMsgs
            liftIO $ B.writeFile json_file (encode msgs)
        Nothing -> return ()

runMainLoop :: EQR eq ctx cc => ctx -> [Property eq] -> [Theorem eq] -> HS ctx
runMainLoop ctx_init initial_props initial_thms = do

    (theorems,conjectures,ctx_final) <- mainLoop ctx_init initial_props initial_thms

    Params{only_user_stated} <- getParams

    let showProperties = map prop_name
        theorems' = map thm_prop
                  $ filter (\ t -> not (definitionalTheorem t) || isUserStated (thm_prop t))
                  $ theorems
        notQS  = filter (not . isFromQS)
        fromQS = filter isFromQS

    writeMsg $ Finished
        { proved      = showProperties $ notQS theorems'
        , unproved    = showProperties $ notQS conjectures
        , qs_proved   = showProperties $ fromQS theorems'
        , qs_unproved =
            if only_user_stated then [] else showProperties $ fromQS conjectures
        }

    return ctx_final

runQuickSpec :: SigInfo -> HS ([Some TypedEquation],[Tagged Term],[Several Expr])
runQuickSpec SigInfo{..} = do

    params@Params{..} <- getParams

    let callg = transitiveCallGraph sig_map

    debugWhen PrintCallGraph $ "\nCall Graph:\n" ++ unlines
        [ show s ++ " calls " ++ show ss
        | (s,ss) <- M.toList callg
        ]


    r <- liftIO $ generate (const totalGen) sig

    let classes = concatMap (some2 (map (Some . O) . TestTree.classes)) (TypeMap.toList r)
        eq_order eq = (assoc_important && not (eqIsAssoc eq), eq)
        swapEq (t :=: u) = u :=: t

        equation_funs :: Some TypedEquation -> [Symbol]
        equation_funs (some eraseEquation -> t1 :=: t2)
            = funs t1 `union` funs t2

        equations' :: [Several Expr] -> [Some TypedEquation]
        equations' = concatMap (several (map Some . toEquations))

        term_calls :: Expr a -> [Symbol]
        term_calls e
            = nubSorted
            . concat
            . mapMaybe (`M.lookup` callg)
            . funs . term $ e

        eq_calls :: TypedEquation a -> [Symbol]
        eq_calls (e1 :==: e2) = nubSorted (term_calls e1 ++ term_calls e2)

        toEquations :: [Expr a] -> [TypedEquation a]
        toEquations es@(x:xs)
            | call_graph = [ toEquation y (reverse ys)
                           | y:ys <- tails (reverse es)
                           , not (null ys)
                           ]
            | otherwise = [ y :==: x | y <- xs ]
        toEquations [] = error "HipSpec.toEquations internal error"

        toEquation :: Expr a -> [Expr a] -> TypedEquation a
        toEquation e rcs = foldr1 best (map (e :==:) rcs)
          where
            best eq1 eq2
                | eq_calls eq1 == term_calls e             = eq1
                | eq_calls eq2 `isSupersetOf` eq_calls eq1 = eq1
                | otherwise                                = eq2

        classToEqs :: [Several Expr] -> [Some TypedEquation]
        classToEqs
            = concatMap
                (sortBy (comparing ( eq_order . (swap_repr ? swapEq)
                                   . some eraseEquation)
                                   )
                )
            . (if call_graph
                   then sortByGraph callg equation_funs
                   else (:[]))
            . if quadratic
                   then concatMap ( several (map (Some . uncurry (:==:))
                                  . uniqueCartesian)
                                  )
                   else equations'

        ctx_init  = NER.initial (maxDepth sig) (symbols sig) reps

        reps = map (some2 (tagged term . head)) classes

        pruner    = prune ctx_init (map erase reps) (some eraseEquation)
        prunedEqs = pruner (equations classes)
        eqs       = prepend_pruned ? (prunedEqs ++) $ classToEqs classes

    debugWhen PrintEqClasses $ "\nEquivalence classes:\n" ++ unlines
        (map show (map (several (map term)) classes))

    writeMsg $ QuickSpecDone (length classes) (length eqs)

    whenFlag params QuickSpecOnly (liftIO exitSuccess)

    return (eqs,reps,classes)

{-

proveTotality :: SigInfo -> [Tagged Term] -> HS (PER.Context,[Theorem Void],[Property Void])
proveTotality SigInfo{..} univ = do

    tot_list <- liftIO $ testTotality sig

    let tot_props
            = [ tot_prop
              | (sym,totality) <- tot_list
              , Just v <- [maybeLookupSym sig_map sym]
              , not (isDataConId v)
              , Just tot_prop <- [totalityProperty v totality]
              ]

    (proved_tot,unproved_tot,NoCC) <- mainLoop NoCC tot_props []

    let ctx_init = PER.initial (maxDepth sig) tot_list univ

    return (ctx_init,proved_tot,unproved_tot)
-}