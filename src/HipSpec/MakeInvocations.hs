{-# LANGUAGE RecordWildCards, ScopedTypeVariables, NamedFieldPuns #-}
module HipSpec.MakeInvocations (tryProve) where

import HipSpec.ATP.Invoke
import HipSpec.ATP.Provers
import HipSpec.ATP.Results

import HipSpec.Property.Repr
import HipSpec.Lang.Renamer
import HipSpec.Id (originalId,Id(ProverBool))

import HipSpec.Monad
import HipSpec.MakeProofs
import HipSpec.ThmLib
import HipSpec.Theory
import HipSpec.Property
import HipSpec.Lemma
import HipSpec.Trim
import HipSpec.Utils

import HipSpec.Lang.Monomorphise
import HipSpec.Lang.PolyFOL (trimDataDecls,uninterpretedInts,skolemise,unlabel)
import HipSpec.Lang.ToPolyFOL (Poly(SK,Id))

import HipSpec.Lang.PrettyTFF (ppLemma,ppRecords)
import HipSpec.Lang.PrettyUtils (PP(..))
import Text.PrettyPrint (vcat,text)

import Data.Traversable (traverse)

import HipSpec.ATP.Z3ProofParser

import Control.Concurrent.STM.Promise.Tree
import Control.Concurrent.STM.Promise.Process (ProcessResult(..))

import Data.List
import Data.Maybe

import Control.Monad

import Jukebox.Toolbox (encodeString)

-- | Try to prove a property, given some lemmas
tryProve :: Property -> [Theorem] -> HS (Maybe Theorem)
tryProve prop lemmas0 = do

    Params{..} <- getParams

    obligss <- makeProofs prop

    if null obligss || any null obligss then return Nothing else do

        Env{theory,arity_map} <- getEnv

        let isolation
                | isolate   = not . isUserStated
                | otherwise = const True

            lemmas
                = filter isolation
                . map thm_prop
                . filter (\ x -> not (definitionalTheorem x) || add_stupid_lemmas)
                $ lemmas0

            enum_lemmas = zip [0..] lemmas

            lemma_theories = map (uncurry (trLemma arity_map)) enum_lemmas

            proof_tree = requireAny (map (requireAll . map Leaf) obligss)

            linTheory :: Theory -> HS LinTheory
            linTheory sthys = do

                let cls = sortClauses False (concatMap clauses sthys)
                let cls_sk = skolemise SK SK cls

                let (mcls_sk,(ils,recs)) = first (sortClauses False) (monoClauses (== Id ProverBool) cls_sk)
                let (mcls,(_ils,_recs))  = first (sortClauses False) (monoClauses (== Id ProverBool) cls)

                let pp = PP (text . polyname) (text . polyname)

                let (smt_str,smt_rename_map) = ppSMT                    (sortClauses True (trimDataDecls mcls_sk))
                let (cvc4_str,_)             = ppSMT (uninterpretedInts (unlabel (sortClauses True (trimDataDecls mcls))))

                let tff = ppTFF mcls

                debugWhen DebugMono $
                    "\nInitial Monomorphising:\n" ++ ppShow cls_sk ++
                    "\nMonomorphising:\n" ++ ppTHF cls_sk ++
                    "\n\nResult:\n" ++ ppTFF mcls_sk ++
                    "\n\nLemmas:\n" ++ render' (vcat (map (ppLemma pp) ils)) ++
                    "\n\nRecords:\n" ++ render' (ppRecords pp recs) ++
                    "\n\nRecords:\n" ++ ppShow recs ++
                    "\nResult Monomorphising:\n" ++ ppShow mcls_sk

                return $ LinTheory smt_rename_map $ \ t -> case t of
                    AltErgoFmt     -> return $ ppAltErgo (sortClauses False cls)
                    AltErgoMonoFmt -> return $ ppMonoAltErgo mcls
                    MonoTFF        -> return tff
                    FOF            -> encodeString tff
                    SMT            -> return $ smt_str ++ "\n(check-sat)\n"
                    SMT_CVC4       -> return $ "(set-logic ALL_SUPPORTED)\n" ++ cvc4_str ++ "\n(check-sat)\n"
                    SMT_PP         -> return $ unlines
                      [ "(set-option :produce-proofs true)"
                      , smt_str
                      , "(echo \"(output \")"
                      , "(check-sat)"
                      , "(get-proof)"
                      , "(echo \")\")"
                      ]

            calc_dependencies :: Subtheory -> [Content]
            calc_dependencies s = concatMap dependencies (s:lemma_theories)

            fetcher :: [Content] -> [Subtheory]
            fetcher = trim (theory ++ lemma_theories)

            fetch_and_linearise :: Subtheory -> HS LinTheory
            fetch_and_linearise conj = linTheory $
                conj : lemma_theories ++ fetcher (calc_dependencies conj)

        proof_tree_lin :: Tree (Obligation LinTheory) <-
            traverse (traverse fetch_and_linearise) proof_tree

        let invoke_env = InvokeEnv
                { timeout         = timeout
                , store           = output
                , provers         = proversFromNames provers
                , processes       = processes
                , z_encode        = z_encode_filenames
                }

        results :: [Obligation Result] <- invokeATPs proof_tree_lin invoke_env

        forM_ results $ \ Obligation{..} -> do
            let (prover,res) = ob_content
            case res of
                Unknown ProcessResult{..} ->
                    writeMsg UnknownResult
                        { property_name = prop_name ob_prop
                        , prop_ob_info  = ob_info
                        , used_prover   = show prover
                        , m_stdout      = stdout
                        , m_stderr      = stderr
                        , m_excode      = show excode
                        }
                _ -> return ()

        let lemma_lkup :: Int -> Property
            lemma_lkup = fromJust . flip lookup enum_lemmas

            res = resultsForProp lemma_lkup results prop

        case res of
            Just Theorem{..} -> writeMsg Proof
                { property_name = prop_name thm_prop
                , property_repr = maybePropRepr thm_prop
                , used_lemmas   = fmap (map prop_name) thm_lemmas
                , used_insts    = thm_insts
                , used_provers  = map show thm_provers
                , used_tech     = thm_proof
                }

            Nothing ->
                writeMsg FailedProof
                    { property_name = prop_name prop
                    , property_repr = maybePropRepr prop
                    }

        return res

resultsForProp :: (Int -> Property) -> [Obligation Result] -> Property -> Maybe Theorem
resultsForProp lemma_lkup results prop = case proofs of
    []    -> Nothing
    grp:_ -> case take 1 grp of
        [] -> error "MakeInvocations: results (impossible)"
        [Obligation _ (ObInduction cs _ _ _sks _sk_tms) _] ->
            mkProof (ByInduction (varsFromCoords prop cs))
        [Obligation _ (ObFixpointInduction{fpi_repr}) _] ->
            mkProof (ByFixpointInduction fpi_repr)
      where
        mkProof pf = Just Theorem
            { thm_prop = prop
            , thm_proof = pf
            , thm_provers = nub $ map (fst . ob_content) grp
            , thm_lemmas
                = fmap (map lemma_lkup . nub . concat)
                $ mapM (successLemmas . snd . ob_content) grp
            , thm_insts = intercalate "\n" (mapMaybe insts grp)
            }

        insts (Obligation _ i (_,Success{..})) = case successInsts of
          Nothing   -> Nothing -- Just "<no info>"
          Just inst -> Just $ intercalate ", " (map (exprRepr . renameWith (disambig originalId)) (ind_terms i))
                              ++ ":\n" ++ prettyInsts inst
        insts _ = error "internal error: Not a success!"
  where
    resType ObInduction{..}         = Left  ind_coords
    resType ObFixpointInduction{..} = Right fpi_repr

    results' = [ ob | ob@Obligation{..} <- results
                    , prop_name prop == prop_name ob_prop
                    , isSuccess (snd ob_content)
               ]

    proofs :: [[Obligation Result]]
    proofs = filter check $ groupSortedOn (resType . ob_info) results'

    check :: [Obligation Result] -> Bool
    check grp@(Obligation _ (ObInduction _ _ nums _ _) _:_) =
        all (\ n -> any ((n ==) . ind_num . ob_info) grp) [0..nums-1]
    check grp@(Obligation _ (ObFixpointInduction{}) _:rs) = length grp == 2 && length (nub (map (fpi_step . ob_info) grp)) == 2
    check _ = False

