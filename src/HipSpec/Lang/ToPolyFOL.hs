{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable, RecordWildCards, ViewPatterns #-}
-- | Translation from the Functional FO to PolyFOL,
-- the only thing that needs to be done is getting rid of case,
-- and translating some types.
module HipSpec.Lang.ToPolyFOL where

import Data.Foldable (Foldable)
import Data.Traversable (Traversable)

import qualified HipSpec.Lang.Type as T

import qualified HipSpec.Lang.FunctionalFO as FO
import HipSpec.Lang.FunctionalFO hiding (App,Ptr)
import HipSpec.Lang.PolyFOL as P
import HipSpec.Lang.TypedScope

import HipSpec.Lang.Rich (Datatype(..),Constructor(..))

import Control.Applicative
import Control.Monad.Reader
import Control.Monad.State

import Data.List (tails)

data Poly v
    = Id v
    -- ^ A normal identifier
    | TyFn
    -- ^ The function type constructor
    | Ptr v
    -- ^ Pointer to an identifier
    | App
    -- ^ The app symbol
    | Proj v Int
    -- ^ Constructor projection on the i:th coordinate
    | QVar Int
    -- ^ Local quantified variable number i
    | IH
    -- ^ The induction hypothesis (in structural induction)
    | Lambda
    -- ^ For beta-reductions in the structural induction hypothesis
    | SK (Poly v) Int
    -- ^ Skolemised, derived variable
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

skolemise :: [Clause (Poly u) (Poly v)] -> [Clause (Poly u) (Poly v)]
skolemise = concatMap sk
  where
    sk (Clause n trg Goal tvs fm) = sk (Clause n trg Axiom tvs (neg fm))
    sk (Clause n trg Axiom tvs (Q Exists vs _trg _id _tm_id b)) =
        [ Clause n trg Axiom [] (substTypes ty_su (substVars (map fst v_su) b)) ] ++
        [ SortSig ty 0 | (_,ty) <- ty_su ] ++
        [ TypeSig v [] t | ((_,v),t) <- v_su ]
      where
        ty_su = [ (tv,SK tv (-i)) | (tv,i) <- zip tvs [0..] ]
        v_su  = [ ((v,SK v i),substTypes ty_su t) | ((v,t),i) <- zip vs [0..] ]
    sk c = [ c ]

data Env v = Env
    { env_fn      :: Poly v
    , env_tvs     :: [Poly v]
    , env_args    :: [Term (Poly v) (Poly v)]
    , env_constrs :: [Formula (Poly v) (Poly v)]
    }

appAxioms :: [Clause (Poly v) (Poly v)]
appAxioms =
    [ SortSig TyFn 2
    , TypeSig App [x,y] [P.TyCon TyFn [x',y'],x'] y'
    ]
  where
    xy@[x,y] = map QVar [0,1]
    [x',y'] = map P.TyVar xy

-- | Makes axioms for a data type
--   TODO : The pointers for the different constructors
trDatatype :: Datatype v -> ([Clause (Poly v) (Poly v)],[(v,[Clause (Poly v) (Poly v)])])
trDatatype (Datatype tc0 tvs0 dcs0) =
    (sort_decl : ty_decls ++ domain : inj ++ discrim,ptrs)
  where
    tc    = Id tc0
    tvs   = map Id tvs0
    tvs'  = map P.TyVar tvs
    tc_ty = P.TyCon tc (map P.TyVar tvs)
    dcs   = [ (dc,map trType args) | Constructor dc args <- dcs0 ]

    trgs  = TySymb tc : map (Symb . Id . fst) dcs

    -- sort declaration
    sort_decl = SortSig tc (length tvs)

    -- smt data declaration
    data_decl = DataDecl
        [Data tc tvs'
            [ (Id dc,[ (Proj dc i,a) | (i,a) <- zip [0..] args ])
            | (dc,args) <- dcs
            ]]

    -- type declarations (also for projections)
    ty_decls = concat
        [ TypeSig (Id dc) tvs args tc_ty :
          [ TypeSig (Proj dc i) tvs [tc_ty] arg
          | (i,arg) <- zip [0..] args
          ]
        | (dc,args) <- dcs
        ]

    -- domain axiom
    domain = Clause Nothing trgs Axiom tvs $ data_decl $ forAll q0 tc_ty $ foldr1 (\/)
        [ Var q0 === Apply (Id dc) tvs'
            [ Apply (Proj dc i) tvs' [Var q0]
            | (i,_) <- zip [0..] args
            ]
        | (dc,args) <- dcs
        ]
      where
        q0 = QVar 0

    -- injectivity axioms
    inj = map (Clause Nothing trgs Axiom tvs . data_decl) $ concat
        [ [ forAlls (zip (map QVar [0..]) args) $
                Apply (Proj dc i) tvs' [tm] === Var (QVar i)
          | (i,_) <- zip [0..] args
          ]
        | (dc,args) <- dcs
        , let tm = Apply (Id dc) tvs' (map fst (zip (map (Var . QVar) [0..]) args))
        ]


    -- discrimination axioms
    discrim = map (Clause Nothing trgs Axiom tvs . data_decl) $
        [ forAlls (qs_k ++ qs_j) (tm_k =/= tm_j)
        | ((k,args_k),(j,args_j)) <- diag dcs
        , let qs_k = zip (map QVar [0..]) args_k
              qs_j = zip (map QVar [length args_k..]) args_j
              tm_k = Apply (Id k) tvs' (map (Var . fst) qs_k)
              tm_j = Apply (Id j) tvs' (map (Var . fst) qs_j)
        ]

    -- ptr axioms
    ptrs = [ (dc,ptrAxiom dc tvs args tc_ty) | (dc,args) <- dcs ]

ptrAxiom :: v -> [Poly v] -> [P.Type (Poly v) (Poly v)] -> P.Type (Poly v) (Poly v) -> [Clause (Poly v) (Poly v)]
ptrAxiom _ _ [] _ = []
ptrAxiom f tvs args res =
    [ TypeSig (Ptr f) tvs [] (foldr ty_fn res args)
    , Clause Nothing [Symb (Ptr f)] Axiom tvs $
        forAlls vars $
            mk_lhs (reverse vars) res ===
            Apply (Id f) (map P.TyVar tvs) (map (Var . fst) vars)
    ]
  where
    ty_fn x y = P.TyCon TyFn [x,y]

    vars = zip (map QVar [0..]) args

    mk_lhs []         _r = Apply (Ptr f) (map P.TyVar tvs) []
    mk_lhs ((x,a):as) r  =
        Apply App
            [a,r]
            [mk_lhs as (ty_fn a r),Var x]


diag :: [a] -> [(a,a)]
diag xs = [ (x,y) | x:ys <- tails xs, y <- ys ]


-- | The scope is typed to be able to write typed quantifiers
--
-- The Env is put in a State instead of Reader because Scope wants to be a
-- reader already
type TrM v a = ReaderT (Scope v (T.Type v)) (State (Env v)) a

trFun :: Ord v => Function v -> ([Clause (Poly v) (Poly v)],[Clause (Poly v) (Poly v)])
trFun (Function f tvs args res_ty body) = (def_cls,ptr_cls)
  where
    f'       = Id f
    tvs'     = map Id tvs
    args'    = map (P.Var . Id . fst) args
    args_ty' = map (trType . snd) args
    res_ty'  = trType res_ty

    mk_def_cls = do
        cls <- case body of
            Just b  -> map (Clause Nothing [Symb f'] Axiom tvs') <$> trBody b
            Nothing -> return []
        let ty_cl = TypeSig f' tvs' args_ty' res_ty'
        return (ty_cl:cls)

    def_cls
        = evalState
            (runReaderT mk_def_cls (makeScope args))
            (Env f' tvs' args' [])


    ptr_cls = ptrAxiom f tvs' args_ty' res_ty'

trBody :: Ord v => Body v -> TrM v [Formula (Poly v) (Poly v)]
trBody b0 = case b0 of
    Case e alts0 -> do
        let (m_def,alts) = partitionAlts alts0
        lhs <- trExpr e

        dres <- case m_def of
            Nothing -> return []
            Just b  -> foldr insertConstraint
                (trBody b) [ lhs =/= P.Lit (get_lit p) | (p,_) <- alts ]
              where
                get_lit p = case p of
                    LitPat i -> i
                    Default  -> error "ToPolyFOL.trBody: duplicate Defaults"
                    ConPat{} -> error "ToPolyFOL.trBody: constructor with Defaults!"

        res <- forM alts $ \ (p,b) -> case p of
            LitPat i -> insertConstraint (lhs === P.Lit i) (trBody b)
            ConPat c tys args -> extendScope args $ do
                let var x = FO.Fun x [] []
                rhs <- trExpr (FO.Fun c tys (map (var . fst) args))
                insertConstraint (lhs === rhs) (trBody b)
            Default -> error "ToPolyFOL.trBody: duplicate Defaults"

        return (dres ++ concat res)

    Body e -> do
        lhs <- trLhs
        rhs <- trExpr e
        scope <- getScope
        let scope' = [ (Id x,trType t) | (x,t) <- scope ]
        constrs <- gets env_constrs
        return [forAlls scope' (constrs ===> lhs === rhs) `withTrigger` lhs]

insertConstraint :: Ord v => Formula (Poly v) (Poly v) -> TrM v a -> TrM v a
insertConstraint phi = case phi of
    TOp Equal (Var (Id x)) tm ->
        removeFromScope x .
        locally
            (\ e -> e
                { env_args    = map (tmSubst (Id x) tm) (env_args e)
                , env_constrs = map (fmSubst (Id x) tm) (env_constrs e)
                }
            )
    _ -> locally (\ e -> e { env_constrs = phi : env_constrs e })

locally :: (Env v -> Env v) -> TrM v a -> TrM v a
locally f m = do
    s <- get
    modify f
    r <- m
    put s
    return r

trLhs :: TrM v (Term (Poly v) (Poly v))
trLhs = do
    Env{..} <- get
    return (P.Apply env_fn (map P.TyVar env_tvs) env_args)

trType :: T.Type v -> P.Type (Poly v) (Poly v)
trType t0 = case t0 of
    T.ArrTy t1 t2 -> P.TyCon TyFn [trType t1,trType t2]
    T.TyVar x     -> P.TyVar (Id x)
    T.TyCon tc ts -> P.TyCon (Id tc) (map trType ts)
    T.Integer     -> P.Integer

trExpr :: Ord v => Expr v -> TrM v (Term (Poly v) (Poly v))
trExpr = go
  where
    go e0 = case e0 of

        FO.Fun f ts as -> do
            b <- inScope f
            if b
                then return (Var (Id f))
                else Apply (Id f) (map trType ts) <$> mapM go as

        FO.App t1 t2 e1 e2 -> Apply App (map trType [t1,t2]) <$> mapM go [e1,e2]

        FO.Ptr f ts -> return (Apply (Ptr f) (map trType ts) [])

        FO.Lit x -> return (P.Lit x)

trExpr' :: Ord v => [v] -> Expr v -> Term (Poly v) (Poly v)
trExpr' scope e =
    evalState
        (runReaderT (trExpr e)
                    (makeScope (zip scope (repeat (error "ToPolyFOL.trExpr' type")))))
        (error "ToPolyFOL.trExpr' Env")

