module Juvix.Compiler.Nockma.Evaluator
  ( module Juvix.Compiler.Nockma.Evaluator,
    module Juvix.Compiler.Nockma.Evaluator.Error,
    module Juvix.Compiler.Nockma.Evaluator.Options,
  )
where

import Juvix.Compiler.Nockma.Evaluator.Error
import Juvix.Compiler.Nockma.Evaluator.Options
import Juvix.Compiler.Nockma.Language
import Juvix.Prelude hiding (Atom, Path)

asAtom :: (Members '[Reader EvalCtx, Error (NockEvalError a)] r) => Term a -> Sem r (Atom a)
asAtom = \case
  TermAtom a -> return a
  TermCell c -> throwExpectedAtom c

asCell :: (Members '[Reader EvalCtx, Error (NockEvalError a)] r) => Term a -> Sem r (Cell a)
asCell = \case
  TermAtom a -> throwExpectedCell a
  TermCell c -> return c

asBool :: (Members '[Reader EvalCtx, Error (NockEvalError a)] r, NockNatural a) => Term a -> Sem r Bool
asBool t = do
  a <- asAtom t
  return (a == nockTrue)

asPath ::
  (Members '[Reader EvalCtx, Error (NockEvalError a), Error (ErrNockNatural a)] r, NockNatural a) =>
  Term a ->
  Sem r Path
asPath = asAtom >=> nockPath

subTermT' :: Path -> Traversal (Term a) (Term a) (First (Term a)) (Term a)
subTermT' pos f = subTermT pos (f . First . Just)

subTermT :: Path -> Traversal' (Term a) (Term a)
subTermT = go
  where
    go :: Path -> (forall f. (Applicative f) => (Term a -> f (Term a)) -> Term a -> f (Term a))
    go = \case
      [] -> id
      d : ds -> \g t -> case t of
        TermAtom {} -> pure t
        TermCell c -> case d of
          L -> (\l' -> TermCell (set cellLeft l' c)) <$> go ds g (c ^. cellLeft)
          R -> (\r' -> TermCell (set cellRight r' c)) <$> go ds g (c ^. cellRight)

subTerm :: (Members '[Reader EvalCtx, Error (NockEvalError a)] r) => Term a -> Path -> Sem r (Term a)
subTerm term pos =
  case term ^? subTermT pos of
    Nothing -> throwInvalidPath term pos
    Just t -> return t

setSubTerm :: forall a r. (Members '[Error (NockEvalError a)] r) => Term a -> Path -> Term a -> Sem r (Term a)
setSubTerm term pos repTerm =
  let (old, new) = setAndRemember (subTermT' pos) repTerm term
   in if
          | isNothing (getFirst old) -> throw @(NockEvalError a) (error "")
          | otherwise -> return new

parseCell ::
  forall r a.
  (Members '[Error (NockEvalError a), Error (ErrNockNatural a)] r, NockNatural a) =>
  Cell a ->
  Sem r (ParsedCell a)
parseCell c = case c ^. cellLeft of
  TermAtom a -> operatorOrStdlibCall a (c ^. cellRight) (c ^. cellCall)
  TermCell l -> return (ParsedAutoConsCell (AutoConsCell l (c ^. cellRight)))
  where
    operatorOrStdlibCall :: Atom a -> Term a -> Maybe (StdlibCall a) -> Sem r (ParsedCell a)
    operatorOrStdlibCall a t mcall = do
      opCell <- parseOperatorCell a t
      return $ case mcall of
        Nothing -> ParsedOperatorCell opCell
        Just call -> ParsedStdlibCallCell (parseStdlibCall opCell call)

    parseStdlibCall :: OperatorCell a -> StdlibCall a -> StdlibCallCell a
    parseStdlibCall op call = StdlibCallCell call op

    parseOperatorCell :: Atom a -> Term a -> Sem r (OperatorCell a)
    parseOperatorCell a t = do
      op <- nockOp a
      return
        OperatorCell
          { _operatorCellOp = op,
            _operatorCellTerm = t
          }

fromReplTerm :: forall a r. (Members '[Error (NockEvalError a)] r) => HashMap Text (Term a) -> ReplTerm a -> Sem r (Term a)
fromReplTerm namedTerms = \case
  ReplName n -> maybe (throw @(NockEvalError a) (ErrAssignmentNotFound n)) return (namedTerms ^. at n)
  ReplTerm t -> return t

programAssignments :: Maybe (Program a) -> HashMap Text (Term a)
programAssignments mprog =
  hashMap
    [ (as ^. assignmentName, as ^. assignmentBody)
      | StatementAssignment as <- mprog ^. _Just . programStatements
    ]

-- | The stack provided in the replExpression has priority
evalRepl ::
  forall r a.
  (Integral a, Members '[Reader EvalOptions, Error (NockEvalError a), Error (ErrNockNatural a)] r, NockNatural a) =>
  (Term a -> Sem r ()) ->
  Maybe (Program a) ->
  Maybe (Term a) ->
  ReplExpression a ->
  Sem r (Term a)
evalRepl handleTrace mprog defaultStack expr = do
  (mstack, t) <- case expr of
    ReplExpressionTerm tm -> return (defaultStack, tm)
    ReplExpressionWithStack w -> do
      t' <- fromReplTerm namedTerms (w ^. withStackStack)
      return (Just t', w ^. withStackTerm)
  stack <- maybe errNoStack return mstack
  fromReplTerm namedTerms t >>= runOutputSem @(Term a) handleTrace . eval stack
  where
    errNoStack :: Sem r x
    errNoStack = throw @(NockEvalError a) (ErrNoStack NoStack)

    namedTerms :: HashMap Text (Term a)
    namedTerms = programAssignments mprog

eval ::
  forall s a.
  (Integral a, Members '[Reader EvalOptions, Output (Term a), Error (NockEvalError a), Error (ErrNockNatural a)] s, NockNatural a) =>
  Term a ->
  Term a ->
  Sem s (Term a)
eval inistack initerm =
  topEvalCtx $
    recEval inistack initerm
  where
    recEval ::
      forall r.
      (r ~ Reader EvalCtx ': s) =>
      Term a ->
      Term a ->
      Sem r (Term a)
    recEval stack term = case term of
      TermAtom a -> throwExpectedCell a
      TermCell c ->
        parseCell c >>= \case
          ParsedAutoConsCell a -> goAutoConsCell a
          ParsedOperatorCell o -> goOperatorCell o
          ParsedStdlibCallCell o -> do
            ignore <- asks (^. evalIgnoreStdlibCalls)
            if
                | ignore -> goOperatorCell (o ^. stdlibCallRaw)
                | otherwise -> goStdlibCall (o ^. stdlibCallCell)
      where
        loc :: Maybe Interval
        loc = term ^. termLoc

        goStdlibCall :: StdlibCall a -> Sem r (Term a)
        goStdlibCall StdlibCall {..} = do
          let w = EvalCrumbStdlibCallArgs (CrumbStdlibCallArgs _stdlibCallFunction)
          args' <- withCrumb w (recEval stack _stdlibCallArgs)
          let binArith :: (a -> a -> a) -> Sem r (Term a)
              binArith f = case args' of
                TCell (TAtom l) (TAtom r) -> return (TCell (TAtom (f l r)) stack)
                _ -> error "expected a cell with two atoms"

              unaArith :: (a -> a) -> Sem r (Term a)
              unaArith f = case args' of
                TAtom n -> return (TCell (TAtom (f n)) stack)
                _ -> error "expected an atom"

              binCmp :: (a -> a -> Bool) -> Sem r (Term a)
              binCmp f = case args' of
                TCell (TAtom l) (TAtom r) -> return (TCell (TermAtom (nockBool (f l r))) stack)
                _ -> error "expected a cell with two atoms"

          case _stdlibCallFunction of
            StdlibDec -> unaArith pred
            StdlibAdd -> binArith (+)
            StdlibMul -> binArith (*)
            StdlibSub -> binArith (-)
            StdlibDiv -> binArith div
            StdlibMod -> binArith mod
            StdlibLt -> binCmp (<)
            StdlibLe -> binCmp (<=)

        goAutoConsCell :: AutoConsCell a -> Sem r (Term a)
        goAutoConsCell c = do
          let w a =
                EvalCrumbAutoCons
                  CrumbAutoCons
                    { _crumbAutoConsTag = a,
                      _crumbAutoConsLoc = loc
                    }
          l' <- withCrumb (w crumbEvalFirst) (recEval stack (TermCell (c ^. autoConsCellLeft)))
          r' <- withCrumb (w crumbEvalSecond) (recEval stack (c ^. autoConsCellRight))
          return (TermCell (Cell l' r'))

        goOperatorCell :: OperatorCell a -> Sem r (Term a)
        goOperatorCell c = case c ^. operatorCellOp of
          OpAddress -> goOpAddress
          OpQuote -> return goOpQuote
          OpApply -> goOpApply
          OpIsCell -> goOpIsCell
          OpInc -> goOpInc
          OpEq -> goOpEq
          OpIf -> goOpIf
          OpSequence -> goOpSequence
          OpPush -> goOpPush
          OpCall -> goOpCall
          OpReplace -> goOpReplace
          OpHint -> goOpHint
          OpTrace -> goOpTrace
          where
            crumb crumbTag =
              EvalCrumbOperator $
                CrumbOperator
                  { _crumbOperatorOp = c ^. operatorCellOp,
                    _crumbOperatorTag = crumbTag,
                    _crumbOperatorLoc = loc
                  }

            evalArg :: CrumbTag -> Term a -> Term a -> Sem r (Term a)
            evalArg crumbTag stack' arg = do
              withCrumb (crumb crumbTag) (recEval stack' arg)

            goOpAddress :: Sem r (Term a)
            goOpAddress = do
              cr <- withCrumb (crumb crumbDecodeFirst) (asPath (c ^. operatorCellTerm))
              withCrumb (crumb crumbEval) (subTerm stack cr)

            goOpQuote :: Term a
            goOpQuote = c ^. operatorCellTerm

            goOpIsCell :: Sem r (Term a)
            goOpIsCell = do
              cr <- evalArg crumbEvalFirst stack (c ^. operatorCellTerm)
              return . TermAtom $ case cr of
                TermCell {} -> nockTrue
                TermAtom {} -> nockFalse

            goOpTrace :: Sem r (Term a)
            goOpTrace = do
              Cell' tr a _ <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              tr' <- evalArg crumbEvalFirst stack tr
              output tr'
              evalArg crumbEvalSecond stack a

            goOpHint :: Sem r (Term a)
            goOpHint = do
              -- Ignore the hint and evaluate
              h <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              evalArg crumbEvalFirst stack (h ^. cellRight)

            goOpPush :: Sem r (Term a)
            goOpPush = do
              cellTerm <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              l <- evalArg crumbEvalFirst stack (cellTerm ^. cellLeft)
              let s = TermCell (Cell l stack)
              evalArg crumbEvalSecond s (cellTerm ^. cellRight)

            goOpReplace :: Sem r (Term a)
            goOpReplace = do
              Cell' rot1 t2 _ <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              Cell' ro t1 _ <- withCrumb (crumb crumbDecodeSecond) (asCell rot1)
              r <- withCrumb (crumb crumbDecodeThird) (asPath ro)
              t1' <- evalArg crumbEvalFirst stack t1
              t2' <- evalArg crumbEvalSecond stack t2
              setSubTerm t2' r t1'

            goOpApply :: Sem r (Term a)
            goOpApply = do
              cellTerm <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              t1' <- evalArg crumbEvalFirst stack (cellTerm ^. cellLeft)
              t2' <- evalArg crumbEvalSecond stack (cellTerm ^. cellRight)
              evalArg crumbEvalSecond t1' t2'

            goOpIf :: Sem r (Term a)
            goOpIf = do
              cellTerm <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              let t0 = cellTerm ^. cellLeft
              Cell' t1 t2 _ <- withCrumb (crumb crumbDecodeSecond) (asCell (cellTerm ^. cellRight))
              cond <- evalArg crumbEvalFirst stack t0 >>= asBool
              if
                  | cond -> evalArg crumbTrueBranch stack t1
                  | otherwise -> evalArg crumbFalseBranch stack t2

            goOpInc :: Sem r (Term a)
            goOpInc =
              TermAtom . nockSucc
                <$> ( evalArg crumbEvalFirst stack (c ^. operatorCellTerm)
                        >>= withCrumb (crumb crumbDecodeFirst) . asAtom
                    )

            goOpEq :: Sem r (Term a)
            goOpEq = do
              cellTerm <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              l <- evalArg crumbEvalFirst stack (cellTerm ^. cellLeft)
              r <- evalArg crumbEvalSecond stack (cellTerm ^. cellRight)
              return . TermAtom $
                if
                    | l == r -> nockTrue
                    | otherwise -> nockFalse

            goOpCall :: Sem r (Term a)
            goOpCall = do
              cellTerm <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              r <- withCrumb (crumb crumbDecodeSecond) (asPath (cellTerm ^. cellLeft))
              t' <- evalArg crumbEvalFirst stack (cellTerm ^. cellRight)
              subTerm t' r >>= evalArg crumbEvalSecond t'

            goOpSequence :: Sem r (Term a)
            goOpSequence = do
              cellTerm <- withCrumb (crumb crumbDecodeFirst) (asCell (c ^. operatorCellTerm))
              t1' <- evalArg crumbEvalFirst stack (cellTerm ^. cellLeft)
              evalArg crumbEvalSecond t1' (cellTerm ^. cellRight)
