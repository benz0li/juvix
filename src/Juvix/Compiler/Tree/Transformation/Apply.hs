module Juvix.Compiler.Tree.Transformation.Apply where

import Data.HashMap.Strict qualified as HashMap
import Juvix.Compiler.Tree.Extra.Apply
import Juvix.Compiler.Tree.Extra.Base
import Juvix.Compiler.Tree.Extra.Recursors
import Juvix.Compiler.Tree.Transformation.Base

computeFunctionApply :: ApplyBuiltins -> Node -> Node
computeFunctionApply blts = umap go
  where
    go :: Node -> Node
    go = \case
      CallClosures NodeCallClosures {..} -> goApply _nodeCallClosuresFun _nodeCallClosuresArgs
      node -> node

    goApply :: Node -> NonEmpty Node -> Node
    goApply cl args
      | n <= m = mkApply cl args
      | otherwise = goApply (mkApply cl (nonEmpty' $ take m args')) (nonEmpty' $ drop m args')
      where
        args' = toList args
        n = length args
        m = blts ^. applyBuiltinsNum

    mkApply :: Node -> NonEmpty Node -> Node
    mkApply cl args =
      Call
        NodeCall
          { _nodeCallInfo = getNodeInfo cl,
            _nodeCallType = CallFun sym,
            _nodeCallArgs = cl : toList args
          }
      where
        sym = fromJust $ HashMap.lookup (length args) (blts ^. applyBuiltinsMap)

computeApply :: InfoTable -> InfoTable
computeApply tab = mapT (const (computeFunctionApply blts)) tab'
  where
    (blts, tab') = addApplyBuiltins tab

checkNoCallClosures :: InfoTable -> Bool
checkNoCallClosures tab =
  all (ufold (\b bs -> b && and bs) go . (^. functionCode)) (tab ^. infoFunctions)
  where
    go :: Node -> Bool
    go = \case
      CallClosures {} -> False
      _ -> True
