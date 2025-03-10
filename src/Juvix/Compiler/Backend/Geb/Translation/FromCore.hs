module Juvix.Compiler.Backend.Geb.Translation.FromCore where

import Data.HashMap.Strict qualified as HashMap
import Data.List qualified as List
import Juvix.Compiler.Backend.Geb.Extra
import Juvix.Compiler.Backend.Geb.Language
import Juvix.Compiler.Core.Data.IdentDependencyInfo qualified as Core
import Juvix.Compiler.Core.Data.InfoTable qualified as Core
import Juvix.Compiler.Core.Extra qualified as Core
import Juvix.Compiler.Core.Info.TypeInfo qualified as Info
import Juvix.Compiler.Core.Language (Index, Level, Symbol)

data Env = Env
  { _envIdentMap :: HashMap Symbol Level,
    _envLevel :: Level,
    -- | `envShiftLevels` contains the de Bruijn levels immediately before which a
    -- | binder was inserted
    _envShiftLevels :: [Level]
  }

emptyEnv :: Env
emptyEnv =
  Env
    { _envIdentMap = mempty,
      _envLevel = 0,
      _envShiftLevels = []
    }

type Trans = Sem '[Reader Env]

makeLenses ''Env

zeroLevel :: Trans a -> Trans a
zeroLevel = local (set envLevel 0)

underBinders :: Int -> Trans a -> Trans a
underBinders n = local (over envLevel (+ n))

underBinder :: Trans a -> Trans a
underBinder = underBinders 1

shifting :: Trans a -> Trans a
shifting m = do
  varsNum <- asks (^. envLevel)
  local (over envShiftLevels (varsNum :)) m

withSymbol :: Symbol -> Trans a -> Trans a
withSymbol sym a = do
  level <- asks (^. envLevel)
  let modif :: Env -> Env =
        over envIdentMap (HashMap.insert sym level)
          . over envLevel (+ 1)
          . over envShiftLevels (0 :)
  local modif a

fromCore :: Core.InfoTable -> (Morphism, Object)
fromCore tab = case tab ^. Core.infoMain of
  Just sym ->
    let node = Core.lookupTabIdentifierNode tab sym
        syms = reverse $ filter (/= sym) $ Core.createCallGraph tab ^. Core.depInfoTopSort
        idents = map (Core.lookupTabIdentifierInfo tab) syms
        morph = run . runReader emptyEnv $ goIdents node idents
        obj = convertType $ Info.getNodeType node
     in (morph, obj)
  Nothing ->
    error "no main function"
  where
    unsupported :: forall a. a
    unsupported = error "unsupported"

    {-
      The translation of each identifier is saved separately to avoid exponential
      blow-up. For example, the program:
      ```
      a : A

      f : A -> A
      f x = F

      g : A -> A
      g x = f (f x)

      main : A
      main = g (g a)
      ```
      is translated as if it were a single node:
      ```
      (\a -> (\f -> (\g -> g (g a)) (\x -> f (f x))) (\x -> F)) a
      ```
    -}
    goIdents :: Core.Node -> [Core.IdentifierInfo] -> Trans Morphism
    goIdents node = \case
      [] ->
        zeroLevel (convertNode node)
      ii : idents -> do
        lamb <- mkLambda
        arg <- zeroLevel (convertNode fundef)
        return $
          MorphismApplication
            Application
              { _applicationLeft = lamb,
                _applicationRight = arg
              }
        where
          sym = ii ^. Core.identifierSymbol
          fundef = Core.lookupTabIdentifierNode tab sym
          argty = convertType (Info.getNodeType fundef)
          mkLambda = do
            body <- withSymbol sym (goIdents node idents)
            return $
              MorphismLambda
                Lambda
                  { _lambdaVarType = argty,
                    _lambdaBody = body
                  }

    convertNode :: Core.Node -> Trans Morphism
    convertNode = \case
      Core.NVar x -> convertVar x
      Core.NIdt x -> convertIdent x
      Core.NCst x -> convertConstant x
      Core.NApp x -> convertApp x
      Core.NBlt x -> convertBuiltinApp x
      Core.NCtr x -> convertConstr x
      Core.NLam x -> convertLambda x
      Core.NLet x -> convertLet x
      Core.NCase x -> convertCase x
      Core.NRec {} -> unsupported -- LetRecs should be lifted out beforehand
      Core.NMatch {} -> unsupported -- Pattern matching should be compiled beforehand
      Core.NPi {} -> unsupported
      Core.NUniv {} -> unsupported
      Core.NTyp {} -> unsupported
      Core.NPrim {} -> unsupported
      Core.NDyn {} -> unsupported
      Core.NBot {} -> unsupported
      Core.Closure {} -> unsupported

    insertedBinders :: Level -> [Level] -> Index -> Int
    insertedBinders varsNum shiftLevels idx =
      length (filter ((varsNum - idx) <=) shiftLevels)

    convertVar :: Core.Var -> Trans Morphism
    convertVar Core.Var {..} = do
      varsNum <- asks (^. envLevel)
      shiftLevels <- asks (^. envShiftLevels)
      let newIdx = _varIndex + insertedBinders varsNum shiftLevels _varIndex
      return $ MorphismVar Var {_varIndex = newIdx}

    convertIdent :: Core.Ident -> Trans Morphism
    convertIdent Core.Ident {..} = do
      varsNum <- asks (^. envLevel)
      shiftLevels <- asks (^. envShiftLevels)
      identMap <- asks (^. envIdentMap)
      let newIdx = varsNum + length shiftLevels - fromJust (HashMap.lookup _identSymbol identMap) - 1
      return $ MorphismVar Var {_varIndex = newIdx}

    convertConstant :: Core.Constant -> Trans Morphism
    convertConstant Core.Constant {..} = case _constantValue of
      Core.ConstInteger n -> return $ MorphismInteger (BitChoice {_bitChoice = n})
      Core.ConstString {} -> unsupported

    convertApp :: Core.App -> Trans Morphism
    convertApp Core.App {..} = do
      _applicationLeft <- convertNode _appLeft
      _applicationRight <- convertNode _appRight
      return $
        MorphismApplication
          Application
            { _applicationLeft,
              _applicationRight
            }

    convertBuiltinApp :: Core.BuiltinApp -> Trans Morphism
    convertBuiltinApp Core.BuiltinApp {..} = case _builtinAppOp of
      Core.OpIntAdd -> convertBinop OpAdd _builtinAppArgs
      Core.OpIntSub -> convertBinop OpSub _builtinAppArgs
      Core.OpIntMul -> convertBinop OpMul _builtinAppArgs
      Core.OpIntDiv -> convertBinop OpDiv _builtinAppArgs
      Core.OpIntMod -> convertBinop OpMod _builtinAppArgs
      Core.OpIntLt -> convertBinop OpLt _builtinAppArgs
      Core.OpIntLe -> convertOpIntLe _builtinAppArgs
      Core.OpEq -> convertOpEq _builtinAppArgs
      Core.OpFail -> convertOpFail (Info.getInfoType _builtinAppInfo) _builtinAppArgs
      _ ->
        unsupported

    convertBinop :: Opcode -> [Core.Node] -> Trans Morphism
    convertBinop op = \case
      [arg1, arg2] -> do
        arg1' <- convertNode arg1
        arg2' <- convertNode arg2
        return $
          MorphismBinop
            Binop
              { _binopOpcode = op,
                _binopLeft = arg1',
                _binopRight = arg2'
              }
      _ ->
        error "wrong builtin application argument number"

    convertOpIntLe :: [Core.Node] -> Trans Morphism
    convertOpIntLe = \case
      [arg1, arg2] -> do
        arg1' <- convertNode arg1
        arg2' <- convertNode arg2
        let le =
              MorphismLambda
                Lambda
                  { _lambdaVarType = ObjectInteger,
                    _lambdaBody =
                      MorphismLambda
                        Lambda
                          { _lambdaVarType = ObjectInteger,
                            _lambdaBody =
                              mkOr
                                ( MorphismBinop
                                    Binop
                                      { _binopOpcode = OpLt,
                                        _binopLeft = MorphismVar Var {_varIndex = 1},
                                        _binopRight = MorphismVar Var {_varIndex = 0}
                                      }
                                )
                                ( MorphismBinop
                                    Binop
                                      { _binopOpcode = OpEq,
                                        _binopLeft = MorphismVar Var {_varIndex = 2},
                                        _binopRight = MorphismVar Var {_varIndex = 1}
                                      }
                                )
                          }
                  }
         in return $
              MorphismApplication
                Application
                  { _applicationLeft =
                      MorphismApplication
                        Application
                          { _applicationLeft = le,
                            _applicationRight = arg1'
                          },
                    _applicationRight = arg2'
                  }
      _ ->
        error "wrong builtin application argument number"

    convertOpEq :: [Core.Node] -> Trans Morphism
    convertOpEq args = case args of
      arg1 : arg2 : _
        | Info.getNodeType arg1 == Core.mkTypeInteger'
            && Info.getNodeType arg2 == Core.mkTypeInteger' ->
            convertBinop OpEq args
      _ ->
        error "unsupported equality argument types"

    convertOpFail :: Core.Type -> [Core.Node] -> Trans Morphism
    convertOpFail ty args = case args of
      [Core.NCst (Core.Constant _ (Core.ConstString msg))] -> do
        return $ MorphismFail (Failure msg (convertType ty))
      _ ->
        error "unsupported fail arguments"

    convertConstr :: Core.Constr -> Trans Morphism
    convertConstr Core.Constr {..} = do
      args <- convertProduct _constrArgs
      unless (tagNum < length constructors) $
        error "constructor tag out of range"
      return $ (constructors !! tagNum) args
      where
        ci = Core.lookupTabConstructorInfo tab _constrTag
        sym = ci ^. Core.constructorInductive
        ctrs = Core.lookupTabInductiveInfo tab sym ^. Core.inductiveConstructors
        tagNum =
          fromJust
            $ elemIndex
              _constrTag
              . sort
            $ ctrs
        constructors = mkConstructors $ convertInductive sym

    mkConstructors :: Object -> [Morphism -> Morphism]
    mkConstructors = \case
      ObjectCoproduct a -> do
        let lType = a ^. coproductLeft
            rType = a ^. coproductRight
            lInj :: Morphism -> Morphism
            lInj x =
              MorphismLeft
                LeftInj
                  { _leftInjRightType = rType,
                    _leftInjValue = x
                  }
            rInj :: Morphism -> Morphism
            rInj x =
              MorphismRight
                RightInj
                  { _rightInjLeftType = lType,
                    _rightInjValue = x
                  }
        lInj : map (rInj .) (mkConstructors rType)
      _ -> [id]

    convertProduct :: [Core.Node] -> Trans Morphism
    convertProduct args = do
      case reverse args of
        h : t -> do
          env <- ask
          let convertNode' = run . runReader env . convertNode
          return $
            fst $
              foldr
                (\x -> mkPair (convertNode' x, convertType (Info.getNodeType x)))
                (convertNode' h, convertType (Info.getNodeType h))
                (reverse t)
        [] -> return MorphismUnit
      where
        mkPair :: (Morphism, Object) -> (Morphism, Object) -> (Morphism, Object)
        mkPair (x, xty) (y, yty) = (z, zty)
          where
            z =
              MorphismPair
                Pair
                  { _pairLeft = x,
                    _pairRight = y
                  }
            zty =
              ObjectProduct
                Product
                  { _productLeft = xty,
                    _productRight = yty
                  }

    convertLet :: Core.Let -> Trans Morphism
    convertLet Core.Let {..} = do
      _lambdaBody <- underBinder (convertNode _letBody)
      let domty = convertType (_letItem ^. Core.letItemBinder . Core.binderType)
      arg <- convertNode (_letItem ^. Core.letItemValue)
      return $
        MorphismApplication
          Application
            { _applicationLeft =
                MorphismLambda
                  Lambda
                    { _lambdaVarType = domty,
                      _lambdaBody
                    },
              _applicationRight = arg
            }

    convertLambda :: Core.Lambda -> Trans Morphism
    convertLambda Core.Lambda {..} = do
      body <- underBinder (convertNode _lambdaBody)
      return $
        MorphismLambda
          Lambda
            { _lambdaVarType = convertType (_lambdaBinder ^. Core.binderType),
              _lambdaBody = body
            }

    convertCase :: Core.Case -> Trans Morphism
    convertCase Core.Case {..} = do
      if
          | null branches -> do
              x <- convertNode _caseValue
              let ty = convertType (Info.getInfoType _caseInfo)
              return $
                MorphismAbsurd
                  Absurd
                    { _absurdType = ty,
                      _absurdValue = x
                    }
          | missingCtrsNum > 1 -> do
              arg <- convertNode defaultNode
              val <- shifting (convertNode _caseValue)
              body <- shifting (go indty val branches)
              let ty = convertType (Info.getNodeType defaultNode)
              return $
                MorphismApplication
                  Application
                    { _applicationLeft =
                        MorphismLambda
                          Lambda
                            { _lambdaVarType = ty,
                              _lambdaBody = body
                            },
                      _applicationRight = arg
                    }
          | otherwise -> do
              val <- convertNode _caseValue
              go indty val branches
      where
        indty = convertInductive _caseInductive
        ii = Core.lookupTabInductiveInfo tab _caseInductive
        missingCtrs =
          filter
            ( \x ->
                isNothing
                  ( find
                      (\y -> x ^. Core.constructorTag == y ^. Core.caseBranchTag)
                      _caseBranches
                  )
            )
            (map (Core.lookupTabConstructorInfo tab) (ii ^. Core.inductiveConstructors))
        missingCtrsNum = length missingCtrs
        ctrBrs = map mkCtrBranch missingCtrs
        defaultNode = fromMaybe (error "not all cases covered") _caseDefault
        -- `branches` contains one branch for each constructor of the inductive type.
        -- `_caseDefault` is the body of those branches which were not present in
        -- `_caseBranches`.
        branches = sortOn (^. Core.caseBranchTag) (_caseBranches ++ ctrBrs)
        codomainType = convertType (Info.getNodeType (List.head branches ^. Core.caseBranchBody))

        mkCtrBranch :: Core.ConstructorInfo -> Core.CaseBranch
        mkCtrBranch ci =
          Core.CaseBranch
            { _caseBranchInfo = mempty,
              _caseBranchTag = ci ^. Core.constructorTag,
              _caseBranchBinders = map (Core.Binder "?" Nothing) tyargs,
              _caseBranchBindersNum = n,
              _caseBranchBody = defaultBody n
            }
          where
            tyargs = Core.typeArgs (ci ^. Core.constructorType)
            n = length tyargs
            defaultBody =
              if
                  | missingCtrsNum > 1 -> Core.mkVar'
                  | otherwise -> (`Core.shift` defaultNode)

        go :: Object -> Morphism -> [Core.CaseBranch] -> Trans Morphism
        go ty val = \case
          [br] -> do
            -- there is only one constructor, so `ty` is a product of its argument types
            mkBranch ty val br
          br : brs -> do
            bodyLeft <- shifting (mkBranch lty (MorphismVar (Var 0)) br)
            bodyRight <- shifting (go rty (MorphismVar (Var 0)) brs)
            return $
              MorphismCase
                Case
                  { _caseOn = val,
                    _caseLeft = bodyLeft,
                    _caseRight = bodyRight
                  }
            where
              (lty, rty) = case ty of
                ObjectCoproduct Coproduct {..} -> (_coproductLeft, _coproductRight)
                _ -> impossible
          [] -> impossible

        mkBranch :: Object -> Morphism -> Core.CaseBranch -> Trans Morphism
        mkBranch valType val Core.CaseBranch {..} = do
          branch <- underBinders _caseBranchBindersNum (convertNode _caseBranchBody)
          if
              | _caseBranchBindersNum == 0 -> return branch
              | _caseBranchBindersNum == 1 ->
                  return $
                    MorphismApplication
                      Application
                        { _applicationLeft =
                            MorphismLambda
                              Lambda
                                { _lambdaVarType = valType,
                                  _lambdaBody = branch
                                },
                          _applicationRight = val
                        }
              | otherwise ->
                  return $ mkApps (mkLambs branch argtys) val argtys
          where
            argtys = destructProduct valType

            -- `mkApps` creates applications of `acc` to extracted components of
            -- `v` which is a product (right-nested)
            mkApps :: Morphism -> Morphism -> [Object] -> Morphism
            mkApps acc v = \case
              _ : tys ->
                mkApps acc' v' tys
                where
                  v' =
                    MorphismSecond
                      Second
                        { _secondValue = v
                        }
                  acc' =
                    MorphismApplication
                      Application
                        { _applicationLeft = acc,
                          _applicationRight =
                            if
                                | null tys ->
                                    v
                                | otherwise ->
                                    MorphismFirst
                                      First
                                        { _firstValue = v
                                        }
                        }
              [] ->
                acc

            mkLambs :: Morphism -> [Object] -> Morphism
            mkLambs br =
              fst
                . foldr
                  ( \ty (acc, accty) ->
                      ( MorphismLambda
                          Lambda
                            { _lambdaVarType = ty,
                              _lambdaBody = acc
                            },
                        ObjectHom
                          Hom
                            { _homDomain = ty,
                              _homCodomain = accty
                            }
                      )
                  )
                  (br, codomainType)

    convertType :: Core.Type -> Object
    convertType = \case
      Core.NPi x -> convertPi x
      Core.NUniv {} -> unsupported -- no polymorphism yet
      Core.NTyp x -> convertTypeConstr x
      Core.NPrim x -> convertTypePrim x
      Core.NDyn {} -> error "incomplete type information (dynamic type encountered)"
      Core.NLam Core.Lambda {..} -> convertType _lambdaBody
      _ -> unsupported

    convertPi :: Core.Pi -> Object
    convertPi Core.Pi {..} =
      ObjectHom
        Hom
          { _homDomain = convertType (_piBinder ^. Core.binderType),
            _homCodomain = convertType _piBody
          }

    convertTypeConstr :: Core.TypeConstr -> Object
    convertTypeConstr Core.TypeConstr {..} = convertInductive _typeConstrSymbol

    convertTypePrim :: Core.TypePrim -> Object
    convertTypePrim Core.TypePrim {..} =
      case _typePrimPrimitive of
        Core.PrimInteger {} -> ObjectInteger
        Core.PrimBool {} -> objectBool
        Core.PrimString -> unsupported

    convertInductive :: Symbol -> Object
    convertInductive sym = do
      let ctrs =
            map (Core.lookupTabConstructorInfo tab) $
              sort $
                Core.lookupTabInductiveInfo tab sym ^. Core.inductiveConstructors
      case reverse ctrs of
        ci : ctrs' -> do
          foldr
            ( \x acc ->
                ObjectCoproduct
                  Coproduct
                    { _coproductLeft =
                        convertConstructorType $ x ^. Core.constructorType,
                      _coproductRight = acc
                    }
            )
            (convertConstructorType (ci ^. Core.constructorType))
            (reverse ctrs')
        [] -> ObjectInitial

    convertConstructorType :: Core.Node -> Object
    convertConstructorType ty =
      case reverse (Core.typeArgs ty) of
        hty : tys ->
          foldr
            ( \x acc ->
                ObjectProduct
                  Product
                    { _productLeft = convertType x,
                      _productRight = acc
                    }
            )
            (convertType hty)
            (reverse tys)
        [] -> ObjectTerminal
