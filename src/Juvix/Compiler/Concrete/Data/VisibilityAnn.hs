module Juvix.Compiler.Concrete.Data.VisibilityAnn where

import Juvix.Extra.Serialize
import Juvix.Prelude

data VisibilityAnn
  = VisPublic
  | VisPrivate
  deriving stock (Show, Eq, Ord, Generic)

instance Serialize VisibilityAnn
