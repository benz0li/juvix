module Juvix.Data.Effect.TaggedLock.Base where

import Juvix.Prelude.Base
import Juvix.Prelude.Path

-- | An effect that wraps an action with a lock that is tagged with a relative
-- path.
--
-- The relative path does not need to exist in the filesystem.
data TaggedLock m a where
  WithTaggedLock :: Path Rel File -> m a -> TaggedLock m a

makeSem ''TaggedLock
