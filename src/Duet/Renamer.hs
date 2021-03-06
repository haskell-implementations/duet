{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}

-- At each binding point (lambdas), we need to supply a new unique
-- name, and then rename everything inside the expression.
--
-- For each BindGroup, we should generate the list of unique names
-- first for each top-level thing (which might be mutually
-- independent), and then run the sub-renaming processes, with the new
-- substitutions in scope.
--
-- It's as simple as that.

module Duet.Renamer
  ( renameDataTypes
  , renameBindings
  , renameBindGroups
  , renameExpression
  , renameClass
  , renameInstance
  , predicateToDict
  , operatorTable
  , Specials(Specials)
  ) where

import           Control.Arrow
import           Control.Monad.Catch
import           Control.Monad.Supply
import           Control.Monad.Trans
import           Control.Monad.Writer
import           Data.Char
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Duet.Infer
import           Duet.Printer
import           Duet.Supply
import           Duet.Types

--------------------------------------------------------------------------------
-- Data type renaming (this includes kind checking)

renameDataTypes
  :: (MonadSupply Int m, MonadThrow m)
  => Specials Name
  -> [DataType UnkindedType Identifier]
  -> m [DataType Type Name]
renameDataTypes specials types = do
  typeConstructors <-
    mapM
      (\(DataType name vars cs) -> do
         name' <- supplyTypeName name
         vars' <-
           mapM
             (\(TypeVariable i k) -> do
                i' <- supplyTypeName i
                pure (i, TypeVariable i' k))
             vars
         pure (name, name', vars', cs))
      types
  mapM
    (\(_, name, vars, cs) -> do
       cs' <- mapM (renameConstructor specials typeConstructors vars) cs
       pure (DataType name (map snd vars) cs'))
    typeConstructors

renameConstructor
  :: (MonadSupply Int m, MonadThrow m)
  => Specials Name -> [(Identifier, Name, [(Identifier, TypeVariable Name)], [DataTypeConstructor UnkindedType Identifier])]
  -> [(Identifier, TypeVariable Name)]
  -> DataTypeConstructor UnkindedType Identifier
  -> m (DataTypeConstructor Type Name)
renameConstructor specials typeConstructors vars (DataTypeConstructor name fields) = do
  name' <- supplyConstructorName name
  fields' <- mapM (renameField specials typeConstructors vars name') fields
  pure (DataTypeConstructor name' fields')

renameField
  :: (MonadThrow m, MonadSupply Int m)
  => Specials Name
  -> [(Identifier, Name, [(Identifier, TypeVariable Name)], [DataTypeConstructor UnkindedType Identifier])]
  -> [(Identifier, TypeVariable Name)]
  -> Name
  -> UnkindedType Identifier
  -> m (Type Name)
renameField specials typeConstructors vars name fe = do
  ty <- go fe
  if typeKind ty == StarKind
    then pure ty
    else throwM (ConstructorFieldKind name ty (typeKind ty))
  where
    go =
      \case
        UnkindedTypeConstructor i -> do
          (name', vars') <- resolve i
          pure (ConstructorType (toTypeConstructor name' (map snd vars')))
        UnkindedTypeVariable v ->
          case lookup v vars of
            Nothing -> throwM (UnknownTypeVariable (map snd vars) v)
            Just tyvar -> pure (VariableType tyvar)
        UnkindedTypeApp f x -> do
          f' <- go f
          let fKind = typeKind f'
          case fKind of
            FunctionKind argKind _ -> do
              x' <- go x
              let xKind = typeKind x'
              if xKind == argKind
                then pure (ApplicationType f' x')
                else throwM (KindArgMismatch f' fKind x' xKind)
            StarKind -> do
              x' <- go x
              throwM (KindTooManyArgs f' fKind x')
    resolve i =
      case find ((\(j, _, _, _) -> j == i)) typeConstructors of
        Just (_, name', vs, _) -> pure (name', vs)
        Nothing ->
          case specialTypesFunction (specialsTypes specials) of
            TypeConstructor n@(TypeName _ i') _
              | Identifier i' == i -> do
                fvars <-
                  mapM
                    (\vari ->
                       (vari, ) <$>
                       fmap
                         (\varn -> TypeVariable varn StarKind)
                         (supplyTypeVariableName vari))
                    (map Identifier ["a", "b"])
                pure (n, fvars)
            _ ->
              case listToMaybe (mapMaybe (matches i) builtinStarTypes) of
                Just ty -> pure ty
                Nothing ->
                  case find
                         (\case
                            TypeName _ tyi -> Identifier tyi == i
                            _ -> False)
                         (map
                            typeConstructorIdentifier
                            [ specialTypesChar (specialsTypes specials)
                            , specialTypesInteger (specialsTypes specials)
                            , specialTypesRational (specialsTypes specials)
                            , specialTypesString (specialsTypes specials)
                            ]) of
                    Just ty -> pure (ty, [])
                    _ -> throwM (TypeNotInScope [] i)
    matches i t =
      case t of
        DataType n@(TypeName _ i') vs _
          | Identifier i' == i ->
            Just
              ( n
              , mapMaybe
                  (\case
                     (TypeVariable n'@(TypeName _ tyi) k) ->
                       Just (Identifier tyi, TypeVariable n' k)
                     _ -> Nothing)
                  vs)
        _ -> Nothing
    builtinStarTypes = [specialTypesBool (specialsTypes specials)]

--------------------------------------------------------------------------------
-- Class renaming

renameClass
  :: forall m.
     (MonadSupply Int m, MonadThrow m)
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> Class UnkindedType Identifier Label
  -> m (Class Type Name Label)
renameClass specials subs types cls = do
  name <- supplyClassName (className cls)
  classVars <-
    mapM
      (\(TypeVariable i k) -> do
         i' <- supplyTypeName i
         pure (i, TypeVariable i' k))
      (classTypeVariables cls)
  instances <-
    mapM
      (renameInstance' specials subs types classVars)
      (classInstances cls)
  methods' <-
    fmap
      M.fromList
      (mapM
         (\(mname, (Forall vars (Qualified preds ty))) -> do
            name' <- supplyMethodName mname
            methodVars <- mapM (renameMethodTyVar classVars) vars
            let classAndMethodVars = nub (classVars ++ methodVars)
            ty' <- renameType specials classAndMethodVars types ty
            preds' <-
              mapM
                (\(IsIn c tys) ->
                   IsIn <$> substituteClass subs c <*>
                   mapM (renameType specials classAndMethodVars types) tys)
                preds
            pure
              ( name'
              , (Forall (map snd classAndMethodVars) (Qualified preds' ty'))))
         (M.toList (classMethods cls)))
  pure
    (Class
     { className = name
     , classTypeVariables = map snd classVars
     , classSuperclasses = []
     , classInstances = instances
     , classMethods = methods'
     })
  where
    renameMethodTyVar
      :: [(Identifier, TypeVariable Name)]
      -> TypeVariable Identifier
      -> m (Identifier, TypeVariable Name)
    renameMethodTyVar classTable (TypeVariable ident k) =
      case lookup ident classTable of
        Nothing -> do
          i' <- supplyTypeName ident
          pure (ident, TypeVariable i' k)
        Just v -> pure (ident, v)

--------------------------------------------------------------------------------
-- Instance renaming

renameInstance
  :: (MonadThrow m, MonadSupply Int m)
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> [Class Type Name l]
  -> Instance UnkindedType Identifier Label
  -> m (Instance Type Name Label)
renameInstance specials subs types classes inst@(Instance (Forall _ (Qualified _ (IsIn className' _))) _) = do
  {-trace ("renameInstance: Classes: " ++ show (map className classes)) (return ())-}
  table <- mapM (\c -> fmap (, c) (identifyClass (className c))) classes
  {-trace ("renameInstance: Table: " ++ show table) (return ())-}
  case lookup className' table of
    Nothing ->
      do {-trace ("renameInstance: ???" ++ show className') (return ())-}
         throwM
           (IdentifierNotInClassScope
              (M.fromList (map (second className) table))
              className')
    Just typeClass -> do
      vars <-
        mapM
          (\v@(TypeVariable i _) -> fmap (, v) (identifyType i))
          (classTypeVariables typeClass)
      instr <- renameInstance' specials subs types vars inst
      pure instr

renameInstance'
  :: (MonadThrow m, MonadSupply Int m)
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> [(Identifier, TypeVariable Name)]
  -> Instance UnkindedType Identifier Label
  -> m (Instance Type Name Label)
renameInstance' specials subs types _tyVars (Instance (Forall vars (Qualified preds ty)) dict) = do
  let vars0 =
        nub
          (if null vars
              then concat
                     (map
                        collectTypeVariables
                        (case ty of
                           IsIn _ t -> t))
              else vars)
  vars'' <-
    mapM
      (\(TypeVariable i k) -> do
         n <- supplyTypeName i
         pure (i, TypeVariable n k))
      vars0
  preds' <- mapM (renamePredicate specials subs vars'' types) preds
  ty' <- renamePredicate specials subs vars'' types ty
  dict' <- renameDict specials subs types dict  ty'
  pure (Instance (Forall (map snd vars'') (Qualified preds' ty')) dict')
  where
    collectTypeVariables :: UnkindedType i -> [TypeVariable i]
    collectTypeVariables =
      \case
        UnkindedTypeConstructor {} -> []
        UnkindedTypeVariable i -> [TypeVariable i StarKind]
        UnkindedTypeApp f x -> collectTypeVariables f ++ collectTypeVariables x

renameDict
  :: (MonadThrow m, MonadSupply Int m)
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> Dictionary UnkindedType Identifier Label
  -> Predicate Type Name
  -> m (Dictionary Type Name Label)
renameDict specials subs types (Dictionary _ methods) predicate = do
  name' <-
    supplyDictName'
      (Identifier (predicateToDict specials predicate))
  methods' <-
    fmap
      M.fromList
      (mapM
         (\(n, (l, alt)) -> do
            n' <- supplyMethodName n
            alt' <- renameAlt specials subs  types alt
            pure (n', (l, alt')))
         (M.toList methods))
  pure (Dictionary name' methods')

predicateToDict :: Specials Name -> ((Predicate Type Name)) -> String
predicateToDict specials p =
  "$dict" ++ map normalize (printPredicate defaultPrint (specialsTypes specials) p)
  where
    normalize c
      | isDigit c || isLetter c = c
      | otherwise = '_'


renamePredicate
  :: (MonadThrow m, Typish (t i), Identifiable i)
  => Specials Name
  -> Map Identifier Name
  -> [(Identifier, TypeVariable Name)]
  -> [DataType Type Name]
  -> Predicate t i
  -> m (Predicate Type Name)
renamePredicate specials subs tyVars types (IsIn className' types0) =
  do subbedClassName <- substituteClass subs className'
     types' <- mapM (renameType specials tyVars types -- >=> forceStarKind
                    ) types0
     pure (IsIn subbedClassName types')

-- | Force that the type has kind *.
_forceStarKind :: MonadThrow m => Type Name -> m (Type Name)
_forceStarKind ty =
  case typeKind ty of
    StarKind -> pure ty
    _ -> throwM (MustBeStarKind ty (typeKind ty))

renameScheme
  :: (MonadSupply Int m, MonadThrow m, Identifiable i, Typish (t i))
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> Scheme t i t
  -> m (Scheme Type Name Type)
renameScheme specials subs  types (Forall tyvars (Qualified ps ty)) = do
  tyvars' <-
    mapM
      (\(TypeVariable i kind) -> do
         do n <-
              case nonrenamableName i of
                Just k -> pure k
                Nothing -> do
                  i' <- identifyType i
                  supplyTypeName i'
            ident <- identifyType n
            (ident, ) <$> (TypeVariable <$> pure n <*> pure kind))
      tyvars
  ps'  <- mapM (renamePredicate specials subs tyvars' types) ps
  ty' <- renameType specials tyvars' types ty
  pure (Forall (map snd tyvars') (Qualified ps' ty'))

-- | Rename a type, checking kinds, taking names, etc.
renameType
  :: (MonadThrow m, Typish (t i))
  => Specials Name
  -> [(Identifier, TypeVariable Name)]
  -> [DataType Type Name]
  -> t i
  -> m (Type Name)
renameType specials tyVars types t = either go pure (isType t)
  where
    go =
      \case
        UnkindedTypeConstructor i -> do
          ms <- mapM (\p -> fmap (, p) (identifyType (dataTypeName p))) types
          case lookup i ms of
            Nothing -> do
              do specials'' <- sequence specials'
                 case lookup i specials'' of
                   Nothing ->
                     throwM
                       (TypeNotInScope
                          (map dataTypeToConstructor (map snd ms))
                          i)
                   Just t' -> pure (ConstructorType t')
            Just dty -> pure (dataTypeConstructor dty)
        UnkindedTypeVariable i -> do
          case lookup i tyVars of
            Nothing -> throwM (UnknownTypeVariable (map snd tyVars) i)
            Just ty -> do
              pure (VariableType ty)
        UnkindedTypeApp f a -> do
          f' <- go f
          case typeKind f' of
            FunctionKind argKind _ -> do
              a' <- go a
              if typeKind a' == argKind
                then pure (ApplicationType f' a')
                else throwM (KindArgMismatch f' (typeKind f') a' (typeKind a'))
            StarKind -> do
              a' <- go a
              throwM (KindTooManyArgs f' (typeKind f') a')
    specials' =
      [ setup (specialTypesFunction . specialsTypes)
      , setup (specialTypesInteger . specialsTypes)
      , setup (specialTypesChar . specialsTypes)
      , setup (specialTypesRational . specialsTypes)
      , setup (specialTypesString . specialsTypes)
      , setup (dataTypeToConstructor . specialTypesBool . specialsTypes)
      ]
      where
        setup f = do
          i <- identifyType (typeConstructorIdentifier (f specials))
          pure (i, f specials)

--------------------------------------------------------------------------------
-- Value renaming

renameBindGroups
  :: ( MonadSupply Int m
     , MonadThrow m
     , Ord i
     , Identifiable i
     , Typish (UnkindedType i)
     )
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> [BindGroup UnkindedType i Label]
  -> m ([BindGroup Type Name Label], Map Identifier Name)
renameBindGroups specials subs types groups = do
  subs' <-
    fmap
      mconcat
      (mapM
         (\(BindGroup explicit implicit) -> do
            implicit' <- getImplicitSubs subs implicit
            explicit' <- getExplicitSubs subs explicit
            pure (explicit' <> implicit'))
         groups)
  fmap
    (second mconcat . unzip)
    (mapM (renameBindGroup specials subs' types) groups)

renameBindings
  :: (MonadSupply Int m, MonadThrow m, Ord i, Identifiable i, Typish (t i))
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> [Binding t i Label]
  -> m ([Binding Type Name Label], Map Identifier Name)
renameBindings specials subs types bindings = do
  subs' <-
    fmap
      ((<> subs) . M.fromList)
      (mapM
         (\case
            ExplicitBinding (ExplicitlyTypedBinding _ (i, _) _ _) -> do
              v <- identifyValue i
              fmap (v, ) (supplyValueName i)
            ImplicitBinding (ImplicitlyTypedBinding _ (i, _) _) -> do
              v <- identifyValue i
              fmap (v, ) (supplyValueName i))
         bindings)
  bindings' <-
    mapM
      (\case
         ExplicitBinding e ->
           ExplicitBinding <$> renameExplicit specials subs' types e
         ImplicitBinding i ->
           ImplicitBinding <$> renameImplicit specials subs' types i)
      bindings
  pure (bindings', subs')

renameBindGroup
  :: (MonadSupply Int m, MonadThrow m, Ord i, Identifiable i, Typish (t i))
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> BindGroup t i Label
  -> m (BindGroup Type Name Label, Map Identifier Name)
renameBindGroup  specials subs  types (BindGroup explicit implicit) = do
  bindGroup' <-
    BindGroup <$> mapM (renameExplicit specials subs  types) explicit <*>
    mapM (mapM (renameImplicit specials subs  types)) implicit
  pure (bindGroup', subs)

getImplicitSubs
  :: (MonadSupply Int m, Identifiable i, MonadThrow m)
  => Map Identifier Name
  -> [[ImplicitlyTypedBinding t i l]]
  -> m (Map Identifier Name)
getImplicitSubs subs implicit =
  fmap
    ((<> subs) . M.fromList)
    (mapM
       (\(ImplicitlyTypedBinding _ (i, _) _) -> do
          v <- identifyValue i
          fmap (v, ) (supplyValueName i))
       (concat implicit))

getExplicitSubs
  :: (MonadSupply Int m, Identifiable i, MonadThrow m)
  => Map Identifier Name
  -> [ExplicitlyTypedBinding t i l]
  -> m (Map Identifier Name)
getExplicitSubs subs explicit =
  fmap
    ((<> subs) . M.fromList)
    (mapM
       (\(ExplicitlyTypedBinding _ (i, _) _ _) -> do
          v <- identifyValue i
          fmap (v, ) (supplyValueName i))
       explicit)

renameExplicit
  :: (MonadSupply Int m, MonadThrow m, Identifiable i, Ord i, Typish (t i))
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> ExplicitlyTypedBinding t i Label
  -> m (ExplicitlyTypedBinding Type Name Label)
renameExplicit specials subs  types (ExplicitlyTypedBinding l (i, l') scheme alts) = do
  name <- substituteVar subs i l'
  ExplicitlyTypedBinding l (name, l') <$> renameScheme specials subs  types scheme <*>
    mapM (renameAlt specials subs  types) alts

renameImplicit
  :: (MonadThrow m,MonadSupply Int m,Ord i, Identifiable i, Typish (t i))
  => Specials Name
       -> Map Identifier Name
       -> [DataType Type Name]
  -> ImplicitlyTypedBinding t i Label
  -> m (ImplicitlyTypedBinding Type Name Label)
renameImplicit specials subs types (ImplicitlyTypedBinding l (id',l') alts) =
  do name <- substituteVar subs id' l'
     ImplicitlyTypedBinding l (name, l') <$> mapM (renameAlt specials subs types) alts

renameAlt ::
     (MonadSupply Int m, MonadThrow m, Ord i, Identifiable i, Typish (t i))
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> Alternative t i Label
  -> m (Alternative Type Name Label)
renameAlt specials subs types (Alternative l ps e) =
  do (ps', subs') <- runWriterT (mapM (renamePattern subs) ps)
     let subs'' = M.fromList subs' <> subs
     Alternative l <$> pure ps' <*> renameExpression specials subs'' types e

renamePattern
  :: (MonadSupply Int m, MonadThrow m, Ord i, Identifiable i)
  => Map Identifier Name
  -> Pattern t i l
  -> WriterT [(Identifier, Name)] m (Pattern Type Name l)
renamePattern subs =
  \case
    VariablePattern l i -> do
      name <- maybe (lift (supplyValueName i)) pure (nonrenamableName i)
      v <- identifyValue i
      tell [(v, name)]
      pure (VariablePattern l name)
    WildcardPattern l s -> pure (WildcardPattern l s)
    AsPattern l i p -> do
      name <- supplyValueName i
      v <- identifyValue i
      tell [(v, name)]
      AsPattern l name <$> renamePattern subs p
    LiteralPattern l0 l -> pure (LiteralPattern l0 l)
    ConstructorPattern l i pats ->
      ConstructorPattern l <$> substituteCons subs i <*>
      mapM (renamePattern subs) pats

class Typish t where isType :: t -> Either (UnkindedType Identifier) (Type Name)
instance Typish (Type Name) where isType = Right
instance Typish (UnkindedType Identifier) where isType = Left

renameExpression
  :: forall t i m.
     (MonadThrow m, MonadSupply Int m, Ord i, Identifiable i, Typish (t i))
  => Specials Name
  -> Map Identifier Name
  -> [DataType Type Name]
  -> Expression t i Label
  -> m (Expression Type Name Label)
renameExpression specials subs types = go
  where
    go :: Expression t i Label -> m (Expression Type Name Label)
    go =
      \case
        ParensExpression l e -> ParensExpression l <$> go e
        VariableExpression l i -> VariableExpression l <$> substituteVar subs i l
        ConstructorExpression l i ->
          ConstructorExpression l <$> substituteCons subs i
        ConstantExpression l i -> pure (ConstantExpression l i)
        LiteralExpression l i -> pure (LiteralExpression l i)
        ApplicationExpression l f x -> ApplicationExpression l <$> go f <*> go x
        InfixExpression l x (orig, VariableExpression l0 i) y -> do
          i' <-
            case nonrenamableName i of
              Just nr -> pure nr
              Nothing -> do
                ident <- identifyValue i
                case lookup ident operatorTable of
                  Just f -> pure (f (specialsSigs specials))
                  _ -> throwM (IdentifierNotInVarScope subs ident l0)
          InfixExpression l <$> go x <*> pure (orig, VariableExpression l0 i') <*>
            go y
        InfixExpression l x (orig, o) y ->
          InfixExpression l <$> go x <*> fmap (orig,) (go o) <*> go y
        LetExpression l bindGroup@(BindGroup ex implicit) e -> do
          subs0 <- getImplicitSubs subs implicit
          subs1 <- getExplicitSubs subs ex
          (bindGroup', subs'') <-
            renameBindGroup specials (subs0 <> subs1) types bindGroup
          LetExpression l <$> pure bindGroup' <*>
            renameExpression specials subs'' types e
        LambdaExpression l alt ->
          LambdaExpression l <$> renameAlt specials subs types alt
        IfExpression l x y z -> IfExpression l <$> go x <*> go y <*> go z
        CaseExpression l e pat_exps ->
          CaseExpression l <$> go e <*>
          mapM
            (\(CaseAlt l1 pat ex) -> do
               (pat', subs') <- runWriterT (renamePattern subs pat)
               e' <-
                 renameExpression specials (M.fromList subs' <> subs) types ex
               pure (CaseAlt l1 pat' e'))
            pat_exps

--------------------------------------------------------------------------------
-- Provide a substitution

substituteVar :: (Identifiable i, MonadThrow m) => Map Identifier Name -> i -> Label -> m Name
substituteVar subs i0 l =
  case nonrenamableName i0 of
    Nothing -> do
      i <- identifyValue i0
      case M.lookup i subs of
        Just name@ValueName {} -> pure name
        Just name@MethodName {} -> pure name
        Just name@DictName {} -> pure name
        _ -> do
          s <- identifyValue i
          throwM (IdentifierNotInVarScope subs s l)
    Just n -> pure n

substituteClass :: (Identifiable i, MonadThrow m) => Map Identifier Name -> i -> m Name
substituteClass subs i0 =
  do i <- identifyValue i0
     case M.lookup i subs of
       Just name@ClassName{} -> pure name
       _ -> do s <- identifyValue i
               throwM (IdentifierNotInClassScope subs s)

substituteCons :: (Identifiable i, MonadThrow m) => Map Identifier Name -> i -> m Name
substituteCons subs i0 =
  do i <- identifyValue i0
     case M.lookup i subs of
       Just name@ConstructorName{} -> pure name
       _ -> do  throwM (IdentifierNotInConScope subs i)

operatorTable :: [(Identifier, SpecialSigs i -> i)]
operatorTable =
  map
    (first Identifier)
    [ ("+", specialSigsPlus)
    , ("-", specialSigsSubtract)
    , ("*", specialSigsTimes)
    , ("/", specialSigsDivide)
    ]
