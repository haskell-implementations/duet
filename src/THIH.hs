{-# OPTIONS -Wno-incomplete-patterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | A clear-to-read, well-documented, implementation of a Haskell 98
-- type checker adapted from Typing Haskell In Haskell, by Mark
-- P. Jones.

module THIH
  ( tiProgram
  , addClass
  , addInstance
  , initialEnv
  , tiProgram'
  , Type(..)
  , Expression(..)
  , Literal(..)
  , Kind(..)
  , Instantiate(..)
  , Scheme(..)
  , Pattern(..)
  , Assumption(..)
  , ClassEnvironment(..)
  , BindGroup(..)
  , ImplicitlyTypedBinding(..)
  , ExplicitlyTypedBinding(..)
  , Alternative(..)
  , TypeVariable(..)
  , Qualified(..)
  , Class(..)
  , Identifier(..)
  , Predicate(..)
  , TypeConstructor(..)
  ) where

import qualified Control.Monad
import           Control.Monad hiding (ap)
import           Data.List
import           Data.String

--------------------------------------------------------------------------------
-- Types

-- | Assumptions about the type of a variable are represented by
-- values of the Assump datatype, each of which pairs a variable name
-- with a type scheme.
data Assumption = Assumption
  { assumptionIdentifier :: Identifier
  , assumptionScheme :: Scheme
  }

-- | The first component in each such pair lists any explicitly typed
-- bindings in the group. The second component provides an opportunity
-- to break down the list of any implicitly typed bindings into
-- several smaller lists, arranged in dependency order. In other
-- words, if a binding group is represented by a pair
-- (es,[is_1,...,is_n]), then the implicitly typed bindings in each
-- is_i should depend only on the bindings in es, is_1, ..., is_i, and
-- not on any bindings in is_j when j>i. (Bindings in es could depend
-- on any of the bindings in the group, but will presumably depend on
-- at least those in is_n, or else the group would not be
-- minimal. Note also that if es is empty, then n must be 1.) In
-- choosing this representation, we have assumed that dependency
-- analysis has been carried out prior to type checking, and that the
-- bindings in each group have been organized into values of type
-- BindGroup as appropriate. In particular, by separating out
-- implicitly typed bindings as much as possible, we can potentially
-- increase the degree of polymorphism in inferred types. For a
-- correct implementation of the semantics specified in the Haskell
-- report, a simpler but less flexible approach is required: all
-- implicitly typed bindings must be placed in a single list, even if
-- a more refined decomposition would be possible. In addition, if the
-- group is restricted, then we must also ensure that none of the
-- explicitly typed bindings in the same BindGroup have any predicates
-- in their type, even though this is not strictly necessary. With
-- hindsight, these are restrictions that we might prefer to avoid in
-- any future revision of Haskell.
data BindGroup = BindGroup
  { bindGroupExplicitlyTypedBindings :: ![ExplicitlyTypedBinding]
  , bindGroupImplicitlyTypedBindings :: ![[ImplicitlyTypedBinding]]
  }

-- | A single implicitly typed binding is described by a pair
-- containing the name of the variable and a list of alternatives.
-- The monomorphism restriction is invoked when one or more of the
-- entries in a list of implicitly typed bindings is simple, meaning
-- that it has an alternative with no left-hand side patterns.
data ImplicitlyTypedBinding = ImplicitlyTypedBinding
  { implicitlyTypedBindingId :: !Identifier
  , implicitlyTypedBindingAlternatives :: ![Alternative]
  }

-- | The simplest case is for explicitly typed bindings, each of which
-- is described by the name of the function that is being defined, the
-- declared type scheme, and the list of alternatives in its
-- definition.
--
-- Haskell requires that each Alt in the definition of a given
-- identifier has the same number of left-hand side arguments, but we
-- do not need to enforce that here.
data ExplicitlyTypedBinding = ExplicitlyTypedBinding
  { explicitlyTypedBindingId :: !Identifier
  , explicitlyTypedBindingScheme :: !Scheme
  , explicitlyTypedBindingAlternatives :: ![Alternative]
  }

-- | Suppose, for example, that we are about to qualify a type with a
-- list of predicates ps and that vs lists all known variables, both
-- fixed and generic. An ambiguity occurs precisely if there is a type
-- variable that appears in ps but not in vs (i.e., in tv ps \\
-- vs). The goal of defaulting is to bind each ambiguous type variable
-- v to a monotype t. The type t must be chosen so that all of the
-- predicates in ps that involve v will be satisfied once t has been
-- substituted for v.
data Ambiguity = Ambiguity
  { ambiguityTypeVariable :: !TypeVariable
  , ambiguityPredicates :: ![Predicate]
  }

-- | An Alt specifies the left and right hand sides of a function
-- definition. With a more complete syntax for Expr, values of type
-- Alt might also be used in the representation of lambda and case
-- expressions.
data Alternative = Alternative
  { alternativePatterns :: ![Pattern]
  , alternativeExpression :: !Expression
  }

-- | Substitutions-finite functions, mapping type variables to
-- types-play a major role in type inference.
data Substitution = Substitution
  { substitutionTypeVariable :: !TypeVariable
  , substitutionType :: !Type
  }

-- | A type variable.
data TypeVariable = TypeVariable
  { typeVariableIdentifier :: !Identifier
  , typeVariableKind :: !Kind
  } deriving (Eq)

-- | An identifier used for variables.
newtype Identifier = Identifier
  { identifierString :: String
  } deriving (Eq, IsString)

-- | Haskell types can be qualified by adding a (possibly empty) list
-- of predicates, or class constraints, to restrict the ways in which
-- type variables are instantiated.
data Qualified typ = Qualified
  { qualifiedPredicates :: ![Predicate]
  , qualifiedType :: !typ
  } deriving (Eq)

-- | One of potentially many predicates.
data Predicate =
  IsIn Identifier [Type]
  deriving (Eq)

-- | A simple Haskell type.
data Type
  = VariableType TypeVariable
  | ConstructorType TypeConstructor
  | ApplicationType Type Type
  | GenericType Int
  deriving (Eq)

-- | Kind of a type.
data Kind
  = StarKind
  | FunctionKind Kind Kind
  deriving (Eq)

-- | A Haskell expression.
data Expression
  = VariableExpression Identifier
  | LiteralExpression Literal
  | ConstantExpression Assumption
  | ApplicationExpression Expression Expression
  | LetExpression BindGroup Expression
  | LambdaExpression Alternative
  | IfExpression Expression Expression Expression
  | CaseExpression Expression [(Pattern, Expression)]

-- | A pattern match.
data Pattern
  = VariablePattern Identifier
  | WildcardPattern
  | AsPattern Identifier Pattern
  | LiteralPattern Literal
  | ConstructorPattern Assumption [Pattern]
  | LazyPattern Pattern

data Literal
  = IntegerLiteral Integer
  | CharacterLiteral Char
  | RationalLiteral Rational
  | StringLiteral String

-- | A class environment.
data ClassEnvironment = ClassEnvironment
  { classEnvironmentClasses :: !(Identifier -> Maybe Class)
  , classEnvironmentDefaults :: ![Type]
  }

-- | A class.
data Class = Class
  { classTypeVariables :: ![TypeVariable]
  , classPredicates :: ![Predicate]
  , classQualifiedPredicates :: ![Qualified Predicate]
  }

-- | A type constructor.
data TypeConstructor = TypeConstructor
  { typeConstructorIdentifier :: !Identifier
  , typeConstructorKind :: !Kind
  } deriving (Eq)

-- | A type scheme.
data Scheme =
  Forall [Kind] (Qualified Type)
  deriving (Eq)

--------------------------------------------------------------------------------
-- Functions (to be split up later)

-- | The monomorphism restriction is invoked when one or more of the
-- entries in a list of implicitly typed bindings is simple, meaning
-- that it has an alternative with no left-hand side patterns. The
-- following function provides a way to test for this:
restrictImplicitlyTypedBindings :: [ImplicitlyTypedBinding] -> Bool
restrictImplicitlyTypedBindings = any simple
  where
    simple =
      any (null . alternativePatterns) . implicitlyTypedBindingAlternatives

-- | The following function calculates the list of ambiguous variables
-- and pairs each one with the list of predicates that must be
-- satisfied by any choice of a default:
ambiguities :: [TypeVariable] -> [Predicate] -> [Ambiguity]
ambiguities typeVariables predicates =
  [ Ambiguity typeVariable (filter (elem typeVariable . getTypeVariables) predicates)
  | typeVariable <- getTypeVariables predicates \\ typeVariables
  ]

-- | The unifyTypeVariable function is used for the special case of unifying a
-- variable u with a type t.
unifyTypeVariable :: Monad m => TypeVariable -> Type -> m [Substitution]
unifyTypeVariable typeVariable typ
  | typ == VariableType typeVariable = return nullSubst
  | typeVariable `elem` getTypeVariables typ = fail "occurs check fails"
  | getKind typeVariable /= getKind typ = fail "kinds do not match"
  | otherwise = return [Substitution typeVariable typ]

--------------------------------------------------------------------------------
-- Good naming convention, but undocumented

class Substitutable t where
  substitute :: [Substitution] -> t -> t

class HasTypeVariables t where
  getTypeVariables :: t -> [TypeVariable]

class MostGeneralUnify t where
  mostGeneralUnify :: Monad m => t -> t -> m [Substitution]

class Instantiate t where
  instantiate :: [Type] -> t -> t

class HasKind t where
  getKind :: t -> Kind

class OneWayMatch t where
  match :: Monad m => t -> t -> m [Substitution]

instance Substitutable Assumption where
  substitute substitutions (Assumption identifier scheme) =
    Assumption identifier (substitute substitutions scheme)

instance HasTypeVariables Assumption where
  getTypeVariables (Assumption _  scheme) = getTypeVariables scheme

instance Substitutable t =>
         Substitutable (Qualified t) where
  substitute substitutions (Qualified predicates t) =
    Qualified (substitute substitutions predicates) (substitute substitutions t)

instance HasTypeVariables t =>
         HasTypeVariables (Qualified t) where
  getTypeVariables (Qualified predicates t) =
    getTypeVariables predicates `union` getTypeVariables t

instance Substitutable Predicate where
  substitute substitutions (IsIn identifier types) =
    IsIn identifier (substitute substitutions types)

instance HasTypeVariables Predicate where
  getTypeVariables (IsIn _ types) = getTypeVariables types

instance MostGeneralUnify Predicate where
  mostGeneralUnify = lift mostGeneralUnify

instance OneWayMatch Predicate where
  match = lift match

instance Substitutable Scheme where
  substitute substitutions (Forall kinds qualified) =
    Forall kinds (substitute substitutions qualified)

instance HasTypeVariables Scheme where
  getTypeVariables (Forall _ qualified) = getTypeVariables qualified

instance Substitutable Type where
  substitute substitutions (VariableType typeVariable) =
    case find ((== typeVariable) . substitutionTypeVariable) substitutions of
      Just substitution -> substitutionType substitution
      Nothing -> VariableType typeVariable
  substitute substitutions (ApplicationType type1 type2) =
    ApplicationType
      (substitute substitutions type1)
      (substitute substitutions type2)
  substitute _ typ = typ

instance HasTypeVariables Type where
  getTypeVariables (VariableType typeVariable) = [typeVariable]
  getTypeVariables (ApplicationType type1 type2) =
    getTypeVariables type1 `union` getTypeVariables type2
  getTypeVariables _ = []

instance Substitutable a =>
         Substitutable [a] where
  substitute substitutions = map (substitute substitutions)

instance HasTypeVariables a => HasTypeVariables [a] where
  getTypeVariables = nub . concat . map getTypeVariables
















instance Functor TI where
  fmap = liftM

instance Applicative TI where
  (<*>) = Control.Monad.ap
  pure = return

instance Monad TI where
  return x = TI (\s n -> (s, n, x))
  TI f >>= g =
    TI
      (\s n ->
         case f s n of
           (s', m, x) ->
             let TI gx = g x
             in gx s' m)

type Infer e t = ClassEnvironment -> [Assumption] -> e -> TI ([Predicate], t)

instance Instantiate Type where
  instantiate ts (ApplicationType l r) = ApplicationType (instantiate ts l) (instantiate ts r)
  instantiate ts (GenericType n) = ts !! n
  instantiate _ t = t

instance Instantiate a =>
         Instantiate [a] where
  instantiate ts = map (instantiate ts)

instance Instantiate t =>
         Instantiate (Qualified t) where
  instantiate ts (Qualified ps t) = Qualified (instantiate ts ps) (instantiate ts t)

instance Instantiate Predicate where
  instantiate ts (IsIn c t) = IsIn c (instantiate ts t)

instance HasKind TypeVariable where
  getKind (TypeVariable _ k) = k

instance HasKind TypeConstructor where
  getKind (TypeConstructor _ k) = k

instance HasKind Type where
  getKind (ConstructorType tc) = getKind tc
  getKind (VariableType u) = getKind u
  getKind (ApplicationType t _) =
    case (getKind t) of
      (FunctionKind _ k) -> k

instance MostGeneralUnify Type where
  mostGeneralUnify (ApplicationType l r) (ApplicationType l' r') = do
    s1 <- mostGeneralUnify l l'
    s2 <- mostGeneralUnify (substitute s1 r) (substitute s1 r')
    return (s2 @@ s1)
  mostGeneralUnify (VariableType u) t = unifyTypeVariable u t
  mostGeneralUnify t (VariableType u) = unifyTypeVariable u t
  mostGeneralUnify (ConstructorType tc1) (ConstructorType tc2)
    | tc1 == tc2 = return nullSubst
  mostGeneralUnify _ _ = fail "types do not unify"

instance (MostGeneralUnify t, Substitutable t) =>
         MostGeneralUnify [t] where
  mostGeneralUnify (x:xs) (y:ys) = do
    s1 <- mostGeneralUnify x y
    s2 <- mostGeneralUnify (substitute s1 xs) (substitute s1 ys)
    return (s2 @@ s1)
  mostGeneralUnify [] [] = return nullSubst
  mostGeneralUnify _ _ = fail "lists do not unify"

instance OneWayMatch Type where
  match (ApplicationType l r) (ApplicationType l' r') = do
    sl <- match l l'
    sr <- match r r'
    merge sl sr
  match (VariableType u) t
    | getKind u == getKind t = return [Substitution u t]
  match (ConstructorType tc1) (ConstructorType tc2)
    | tc1 == tc2 = return nullSubst
  match _ _ = fail "types do not match"

instance OneWayMatch t =>
         OneWayMatch [t] where
  match ts ts' = do
    ss <- sequence (zipWith match ts ts')
    foldM merge nullSubst ss

findId
  :: Monad m
  => Identifier -> [Assumption] -> m Scheme
findId i [] = fail ("unbound identifier: " ++ identifierString i)
findId i ((Assumption i'  sc):as) =
  if i == i'
    then return sc
    else findId i as

enumId :: Int -> Identifier
enumId n = Identifier ("v" ++ show n)

tiLit :: Literal -> TI ([Predicate], Type)
tiLit (CharacterLiteral _) = return ([], tChar)
tiLit (IntegerLiteral _) = do
  v <- newVariableType StarKind
  return ([IsIn "Num" [v]], v)
tiLit (StringLiteral _) = return ([], tString)
tiLit (RationalLiteral _) = do
  v <- newVariableType StarKind
  return ([IsIn "Fractional" [v]], v)

tiPat :: Pattern -> TI ([Predicate], [Assumption], Type)
tiPat (VariablePattern i) = do
  v <- newVariableType StarKind
  return ([], [Assumption i (toScheme v)], v)
tiPat WildcardPattern = do
  v <- newVariableType StarKind
  return ([], [], v)
tiPat (AsPattern i pat) = do
  (ps, as, t) <- tiPat pat
  return (ps, (Assumption i (toScheme t)) : as, t)
tiPat (LiteralPattern l) = do
  (ps, t) <- tiLit l
  return (ps, [], t)
tiPat (ConstructorPattern (Assumption _  sc) pats) = do
  (ps, as, ts) <- tiPats pats
  t' <- newVariableType StarKind
  (Qualified qs t) <- freshInst sc
  unify t (foldr fn t' ts)
  return (ps ++ qs, as, t')
tiPat (LazyPattern pat) = tiPat pat

tiPats :: [Pattern] -> TI ([Predicate], [Assumption], [Type])
tiPats pats = do
  psasts <- mapM tiPat pats
  let ps = concat [ps' | (ps', _, _) <- psasts]
      as = concat [as' | (_, as', _) <- psasts]
      ts = [t | (_, _, t) <- psasts]
  return (ps, as, ts)

predHead :: Predicate -> Identifier
predHead (IsIn i _) = i

lift
  :: Monad m
  => ([Type] -> [Type] -> m a) -> Predicate -> Predicate -> m a
lift m (IsIn i ts) (IsIn i' ts')
  | i == i' = m ts ts'
  | otherwise = fail "classes differ"

sig :: ClassEnvironment -> Identifier -> [TypeVariable]
sig ce i =
  case classEnvironmentClasses ce i of
    Just (Class vs _ _) -> vs

super :: ClassEnvironment -> Identifier -> [Predicate]
super ce i =
  case classEnvironmentClasses ce i of
    Just (Class _ is _) -> is

insts :: ClassEnvironment -> Identifier -> [Qualified Predicate]
insts ce i =
  case classEnvironmentClasses ce i of
    Just (Class _ _ its) -> its

defined :: Maybe a -> Bool
defined (Just _) = True
defined Nothing = False

modify :: ClassEnvironment -> Identifier -> Class -> ClassEnvironment
modify ce i c =
  ce
  { classEnvironmentClasses =
      \j ->
        if i == j
          then Just c
          else classEnvironmentClasses ce j
  }

initialEnv :: ClassEnvironment
initialEnv =
  ClassEnvironment
  { classEnvironmentClasses = \_ -> fail "class not defined"
  , classEnvironmentDefaults = [tInteger, tDouble]
  }

addClass :: Identifier -> [TypeVariable] -> [Predicate] -> (ClassEnvironment -> Maybe ClassEnvironment)
addClass i vs ps ce
  | defined (classEnvironmentClasses ce i) = fail "class already defined"
  | any (not . defined . classEnvironmentClasses ce . predHead) ps =
    fail "superclass not defined"
  | otherwise = return (modify ce i (Class vs ps []))

addInstance :: [Predicate] -> Predicate -> (ClassEnvironment -> Maybe ClassEnvironment)
addInstance ps p@(IsIn i _) ce
  | not (defined (classEnvironmentClasses ce i)) = fail "no class for instance"
  | any (overlap p) qs = fail "overlapping instance"
  | otherwise = return (modify ce i c)
  where
    its = insts ce i
    qs = [q | (Qualified _ q) <- its]
    c = (Class (sig ce i) (super ce i) (Qualified ps p : its))

overlap :: Predicate -> Predicate -> Bool
overlap p q = defined (mostGeneralUnify p q)

bySuper :: ClassEnvironment -> Predicate -> [Predicate]
bySuper ce p@(IsIn i ts) = p : concat (map (bySuper ce) supers)
  where
    supers = substitute substitutions (super ce i)
    substitutions = zipWith Substitution (sig ce i) ts

byInst :: ClassEnvironment -> Predicate -> Maybe [Predicate]
byInst ce p@(IsIn i _) = msum [tryInst it | it <- insts ce i]
  where
    tryInst (Qualified ps h) = do
      u <- match h p
      Just (map (substitute u) ps)

entail :: ClassEnvironment -> [Predicate] -> Predicate -> Bool
entail ce ps p =
  any (p `elem`) (map (bySuper ce) ps) ||
  case byInst ce p of
    Nothing -> False
    Just qs -> all (entail ce ps) qs

simplify :: ([Predicate] -> Predicate -> Bool) -> [Predicate] -> [Predicate]
simplify ent = loop []
  where
    loop rs [] = rs
    loop rs (p:ps)
      | ent (rs ++ ps) p = loop rs ps
      | otherwise = loop (p : rs) ps

reduce :: ClassEnvironment -> [Predicate] -> [Predicate]
reduce ce = simplify (scEntail ce) . elimTauts ce

elimTauts :: ClassEnvironment -> [Predicate] -> [Predicate]
elimTauts ce ps = [p | p <- ps, not (entail ce [] p)]

scEntail :: ClassEnvironment -> [Predicate] -> Predicate -> Bool
scEntail ce ps p = any (p `elem`) (map (bySuper ce) ps)

quantify :: [TypeVariable] -> Qualified Type -> Scheme
quantify vs qt = Forall ks (substitute s qt)
  where
    vs' = [v | v <- getTypeVariables qt, v `elem` vs]
    ks = map getKind vs'
    s = zipWith Substitution vs' (map GenericType [0 ..])

toScheme :: Type -> Scheme
toScheme t = Forall [] (Qualified [] t)

nullSubst :: [Substitution]
nullSubst = []

infixr 4 @@

(@@) :: [Substitution] -> [Substitution] -> [Substitution]
s1 @@ s2 = [Substitution u (substitute s1 t) | (Substitution u t) <- s2] ++ s1

merge
  :: Monad m
  => [Substitution] -> [Substitution] -> m [Substitution]
merge s1 s2 =
  if agree
    then return (s1 ++ s2)
    else fail "merge fails"
  where
    agree =
      all
        (\v -> substitute s1 (VariableType v) == substitute s2 (VariableType v))
        (map substitutionTypeVariable s1 `intersect`
         map substitutionTypeVariable s2)

tBool :: Type
tBool = ConstructorType (TypeConstructor "Bool" StarKind)

tiExpression :: Infer Expression Type
tiExpression _ as (VariableExpression i) = do
  sc <- findId i as
  (Qualified ps t) <- freshInst sc
  return (ps, t)
tiExpression _ _ (ConstantExpression (Assumption _  sc)) = do
  (Qualified ps t) <- freshInst sc
  return (ps, t)
tiExpression _ _ (LiteralExpression l) = do
  (ps, t) <- tiLit l
  return (ps, t)
tiExpression ce as (ApplicationExpression e f) = do
  (ps, te) <- tiExpression ce as e
  (qs, tf) <- tiExpression ce as f
  t <- newVariableType StarKind
  unify (tf `fn` t) te
  return (ps ++ qs, t)
tiExpression ce as (LetExpression bg e) = do
  (ps, as') <- tiBindGroup ce as bg
  (qs, t) <- tiExpression ce (as' ++ as) e
  return (ps ++ qs, t)
tiExpression ce as (LambdaExpression alt) = tiAlt ce as alt
tiExpression ce as (IfExpression e e1 e2) = do
  (ps, t) <- tiExpression ce as e
  unify t tBool
  (ps1, t1) <- tiExpression ce as e1
  (ps2, t2) <- tiExpression ce as e2
  unify t1 t2
  return (ps ++ ps1 ++ ps2, t1)
tiExpression ce as (CaseExpression e branches) = do
  (ps0, t) <- tiExpression ce as e
  v <- newVariableType StarKind
  let tiBr (pat, f) = do
        (ps, as', t') <- tiPat pat
        unify t t'
        (qs, t'') <- tiExpression ce (as' ++ as) f
        unify v t''
        return (ps ++ qs)
  pss <- mapM tiBr branches
  return (ps0 ++ concat pss, v)

tiAlt :: Infer Alternative Type
tiAlt ce as (Alternative pats e) = do
  (ps, as', ts) <- tiPats pats
  (qs, t) <- tiExpression ce (as' ++ as) e
  return (ps ++ qs, foldr fn t ts)

tiAlts :: ClassEnvironment -> [Assumption] -> [Alternative] -> Type -> TI [Predicate]
tiAlts ce as alts t = do
  psts <- mapM (tiAlt ce as) alts
  mapM_ (unify t) (map snd psts)
  return (concat (map fst psts))

split
  :: Monad m
  => ClassEnvironment -> [TypeVariable] -> [TypeVariable] -> [Predicate] -> m ([Predicate], [Predicate])
split ce fs gs ps = do
  let ps' = reduce ce ps
      (ds, rs) = partition (all (`elem` fs) . getTypeVariables) ps'
  rs' <- defaultedPredicates ce (fs ++ gs) rs
  return (ds, rs \\ rs')

numClasses :: [Identifier]
numClasses =
  ["Num", "Integral", "Floating", "Fractional", "Real", "RealFloat", "RealFrac"]

stdClasses :: [Identifier]
stdClasses =
  [ "Eq"
  , "Ord"
  , "Show"
  , "Read"
  , "Bounded"
  , "Enum"
  , "Ix"
  , "Functor"
  , "Monad"
  , "MonadPlus"
  ] ++
  numClasses

candidates :: ClassEnvironment -> Ambiguity -> [Type]
candidates ce (Ambiguity v qs) =
  [ t'
  | let is = [i | IsIn i _ <- qs]
        ts = [t | IsIn _ t <- qs]
  , all ([VariableType v] ==) ts
  , any (`elem` numClasses) is
  , all (`elem` stdClasses) is
  , t' <- classEnvironmentDefaults ce
  , all (entail ce []) [IsIn i [t'] | i <- is]
  ]

withDefaults
  :: Monad m
  => ([Ambiguity] -> [Type] -> a) -> ClassEnvironment -> [TypeVariable] -> [Predicate] -> m a
withDefaults f ce vs ps
  | any null tss = fail "cannot resolve ambiguity"
  | otherwise = return (f vps (map head tss))
  where
    vps = ambiguities vs ps
    tss = map (candidates ce) vps

defaultedPredicates
  :: Monad m
  => ClassEnvironment -> [TypeVariable] -> [Predicate] -> m [Predicate]
defaultedPredicates = withDefaults (\vps _ -> concat (map ambiguityPredicates vps))

defaultSubst
  :: Monad m
  => ClassEnvironment -> [TypeVariable] -> [Predicate] -> m [Substitution]
defaultSubst = withDefaults (\vps ts -> zipWith Substitution (map ambiguityTypeVariable vps) ts)

tiExpl :: ClassEnvironment -> [Assumption] -> ExplicitlyTypedBinding -> TI [Predicate]
tiExpl ce as (ExplicitlyTypedBinding _ sc alts) = do
  (Qualified qs t) <- freshInst sc
  ps <- tiAlts ce as alts t
  s <- getSubst
  let qs' = substitute s qs
      t' = substitute s t
      fs = getTypeVariables (substitute s as)
      gs = getTypeVariables t' \\ fs
      sc' = quantify gs (Qualified qs' t')
      ps' = filter (not . entail ce qs') (substitute s ps)
  (ds, rs) <- split ce fs gs ps'
  if sc /= sc'
    then fail "signature too general"
    else if not (null rs)
           then fail "context too weak"
           else return ds

tiImpls :: Infer [ImplicitlyTypedBinding] [Assumption]
tiImpls ce as bs = do
  ts <- mapM (\_ -> newVariableType StarKind) bs
  let is = map implicitlyTypedBindingId bs
      scs = map toScheme ts
      as' = zipWith Assumption is scs ++ as
      altss = map implicitlyTypedBindingAlternatives bs
  pss <- sequence (zipWith (tiAlts ce as') altss ts)
  s <- getSubst
  let ps' = substitute s (concat pss)
      ts' = substitute s ts
      fs = getTypeVariables (substitute s as)
      vss = map getTypeVariables ts'
      gs = foldr1 union vss \\ fs
  (ds, rs) <- split ce fs (foldr1 intersect vss) ps'
  if restrictImplicitlyTypedBindings bs
    then let gs' = gs \\ getTypeVariables rs
             scs' = map (quantify gs' . (Qualified [])) ts'
         in return (ds ++ rs, zipWith Assumption is scs')
    else let scs' = map (quantify gs . (Qualified rs)) ts'
         in return (ds, zipWith Assumption is scs')

tiBindGroup :: Infer BindGroup [Assumption]
tiBindGroup ce as (BindGroup es iss) = do
  let as' = [Assumption v  sc | ExplicitlyTypedBinding v sc _alts <- es]
  (ps, as'') <- tiSeq tiImpls ce (as' ++ as) iss
  qss <- mapM (tiExpl ce (as'' ++ as' ++ as)) es
  return (ps ++ concat qss, as'' ++ as')

tiSeq :: Infer bg [Assumption] -> Infer [bg] [Assumption]
tiSeq _ _ _ [] = return ([], [])
tiSeq ti ce as (bs:bss) = do
  (ps, as') <- ti ce as bs
  (qs, as'') <- tiSeq ti ce (as' ++ as) bss
  return (ps ++ qs, as'' ++ as')

newtype TI a =
  TI ([Substitution] -> Int -> ([Substitution], Int, a))

runTI :: TI a -> a
runTI (TI f) = x
  where
    (_, _, x) = f nullSubst 0

getSubst :: TI [Substitution]
getSubst = TI (\s n -> (s, n, s))

unify :: Type -> Type -> TI ()
unify t1 t2 = do
  s <- getSubst
  u <- mostGeneralUnify (substitute s t1) (substitute s t2)
  extSubst u

trim :: [TypeVariable] -> TI ()
trim vs =
  TI
    (\s n ->
       let s' = [(Substitution v t) | (Substitution v t) <- s, v `elem` vs]
           force = length (getTypeVariables (map substitutionType s'))
       in force `seq` (s', n, ()))

extSubst :: [Substitution] -> TI ()
extSubst s' = TI (\s n -> (s' @@ s, n, ()))

newVariableType :: Kind -> TI Type
newVariableType k =
  TI
    (\s n ->
       let v = TypeVariable (enumId n) k
       in (s, n + 1, VariableType v))

freshInst :: Scheme -> TI (Qualified Type)
freshInst (Forall ks qt) = do
  ts <- mapM newVariableType ks
  return (instantiate ts qt)

tiProgram :: ClassEnvironment -> [Assumption] -> [BindGroup] -> [Assumption]
tiProgram ce as bgs =
  runTI $ do
    (ps, as') <- tiSeq tiBindGroup ce as bgs
    s <- getSubst
    let rs = reduce ce (substitute s ps)
    s' <- defaultSubst ce [] rs
    return (substitute (s' @@ s) as')

tiBindGroup' :: ClassEnvironment -> [Assumption] -> BindGroup -> TI ([Predicate], [Assumption])
tiBindGroup' ce as bs = do
  (ps, as') <- tiBindGroup ce as bs
  trim (getTypeVariables (as' ++ as))
  return (ps, as')

tiProgram' :: ClassEnvironment -> [Assumption] -> [BindGroup] -> [Assumption]
tiProgram' ce as bgs =
  runTI $ do
    (ps, as') <- tiSeq tiBindGroup' ce as bgs
    s <- getSubst
    let rs = reduce ce (substitute s ps)
    s' <- defaultSubst ce [] rs
    return (substitute (s' @@ s) as')

tChar :: Type
tChar = ConstructorType (TypeConstructor "Char" StarKind)

tString :: Type
tString = list tChar

list :: Type -> Type
list t = ApplicationType tList t

tList :: Type
tList = ConstructorType (TypeConstructor "[]" (FunctionKind StarKind StarKind))


fn :: Type -> Type -> Type
a `fn` b = ApplicationType (ApplicationType tArrow a) b

tInteger :: Type
tInteger = ConstructorType (TypeConstructor "Integer" StarKind)

tDouble :: Type
tDouble = ConstructorType (TypeConstructor "Double" StarKind)

tArrow :: Type
tArrow = ConstructorType (TypeConstructor "(->)" (FunctionKind StarKind (FunctionKind StarKind StarKind)))
