-- | Definitions of data types for patterns, matchers, match clauses, matching states, and matching atoms.

module Control.Egison.Core (
  -- * Patterns
  Pattern(..),
  Matcher(..),
  MatchClause(..),
  -- * Matching states and matching atoms
  MState(..),
  MAtom(..),
  MList(..),
  mappend,
  oneMAtom,
  twoMAtoms,
  threeMAtoms,
  -- * Heterogeneous lists
  HList(..),
  happend,
  (:++:),
  ) where

import           Prelude hiding (mappend)
import           Data.Maybe
import           Data.Type.Equality
import           Unsafe.Coerce

---
--- Pattern
---

-- | A pattern for data of a type @a@ for a matcher @m@.
-- @ctx@ is an intermediate pattern-matching result that is a type of a list of data bound in the left-side of the pattern.
-- @vs@ is a list of types bound to the pattern variables in this pattern.
data Pattern a m ctx vs where
  Wildcard     :: (Matcher m a) => Pattern a m ctx '[]
  PatVar       :: (Matcher m a) => String -> Pattern a m ctx '[a]
  AndPat       :: (Matcher m a) => Pattern a m ctx vs -> Pattern a m (ctx :++: vs) vs' -> Pattern a m ctx (vs :++: vs')
  OrPat        :: (Matcher m a) => Pattern a m ctx vs -> Pattern a m ctx vs -> Pattern a m ctx vs
  NotPat       :: (Matcher m a) => Pattern a m ctx '[] -> Pattern a m ctx '[]
  PredicatePat :: (Matcher m a) => (HList ctx -> a -> Bool) -> Pattern a m ctx '[]
  -- | User-defined pattern; pattern is a function that takes a target, an intermediate pattern-matching result, and a matcher and returns a list of lists of matching atoms.
  Pattern      :: (Matcher m a) => (HList ctx -> m -> a -> [MList ctx vs]) -> Pattern a m ctx vs

-- | The @Matcher@ class is used to declare that @m@ is a matcher for data of a type @a@.
-- For example,
-- 
-- > instance (Matcher m a) => Matcher (Multiset m) [a]
-- 
-- declares that "let @m@ be a matcher for @a@, @(Multiset m)@ is a matcher for @[a]@".
class Matcher m a

-- | A match clause of a match expression whose target data is @a@ and matcher is @m@.
-- The body of the match clause is evaluated to @b@.
-- 
-- The first argument of @MatchClause@ is a pattern for @a@ with a matcher @m@.
-- This pattern makes a binding whose type is @vs@.
-- The second argument of @MatchClause@ is a function that takes a heterogeneous list containing @vs@ and returns @b@.
-- 
-- @vs@ is existentially quantified because generally each pattern of the list of match clauses in a pattern-matching expression makes different bindings.
-- 
-- Several samples of @MatchClause@s are found in "Control.Egison.QQ".
-- The 'Control.Egison.QQ.mc' quasiquoter allows us to describe a match clause in user-friendly syntax.
data MatchClause a m b = forall vs. (Matcher m a) => MatchClause (Pattern a m '[] vs) (HList vs -> b)

---
--- Matching state
---

-- | A matching state.
-- A matching state consists of an intermediate pattern-matching result and a stack of matching atoms.
-- @vs@ is a list of types bound to the pattern variables in the pattern after processing @MState@.
data MState vs where
  MState :: vs ~ (xs :++: ys) => HList xs -> MList xs ys -> MState vs

-- | A matching atom.
-- @ctx@ is a intermediate pattern-matching result.
-- @vs@ is a list of types bound to the pattern variables by processing this matching atom.
-- The types of a target @a@ and a matcher @m@ are existentially quantified each matching atom in a stack of matching atoms contains a pattern, matcher, and target for a different type.
data MAtom ctx vs = forall a m. (Matcher m a) => MAtom (Pattern a m ctx vs) m a

-- | A list of matching atoms.
-- It is used to represent a stack of matching atoms in a matching state.
data MList ctx vs where
  MNil :: MList ctx '[]
  MCons :: MAtom ctx xs -> MList (ctx :++: xs) ys -> MList ctx (xs :++: ys)

-- | Concatenate two lists of matching atoms.
mappend :: MList ctx xs -> MList (ctx :++: xs) ys -> MList ctx (xs :++: ys)
mappend MNil atoms = atoms
mappend (MCons atom atoms1) atoms2 =
  case mconsAssocProof atom atoms1 of
    Refl -> case mappendAssocProof atom atoms1 atoms2 of
      Refl -> MCons atom (mappend atoms1 atoms2)

-- | Create a list of a single matching atom.
{-# INLINE oneMAtom #-}
oneMAtom :: MAtom ctx xs -> MList ctx xs
oneMAtom atom1 = MCons atom1 MNil

-- | Create a list of two matching atoms.
{-# INLINE twoMAtoms #-}
twoMAtoms :: MAtom ctx xs -> MAtom (ctx :++: xs) ys -> MList ctx (xs :++: ys)
twoMAtoms atom1 atom2 = MCons atom1 (MCons atom2 MNil)

-- | Create a list of three matching atoms.
{-# INLINE threeMAtoms #-}
threeMAtoms :: MAtom ctx xs -> MAtom (ctx :++: xs) ys -> MAtom (ctx :++: xs :++: ys) zs -> MList ctx (xs :++: ys :++: zs)
threeMAtoms atom1 atom2 atom3 =
  case threeMConsAssocProof atom1 atom2 atom3 of
    Refl -> MCons atom1 (MCons atom2 (MCons atom3 MNil))

-- | Heterogeneous lists.
data HList xs where
  HNil :: HList '[]
  HCons :: a -> HList as -> HList (a ': as)

-- | Axioms for heterogeneous lists.
type family (as ::[*]) :++: (bs :: [*]) :: [*] where
  as :++: '[] = as
  '[] :++: bs = bs
  (a ': as) :++: bs = a ': (as :++: bs)

-- | Concatenate two heterogeneous lists.
happend :: HList as -> HList bs -> HList (as :++: bs)
happend HNil ys         = ys
happend xs@(HCons x xs') ys = case hconsAssocProof x xs' ys of
                                Refl -> HCons x $ happend xs' ys

{-# INLINE hconsAssocProof #-}
hconsAssocProof :: a -> HList as -> HList bs -> ((a ': as) :++: bs) :~: (a ': (as :++: bs))
hconsAssocProof _ _ HNil = Refl
hconsAssocProof x xs (HCons y ys) = Refl

{-# INLINE mconsAssocProof #-}
mconsAssocProof :: MAtom ctx vs -> MList (ctx :++: vs) vs' -> (ctx :++: (vs :++: vs')) :~: ((ctx :++: vs) :++: vs')
mconsAssocProof _ _ = unsafeCoerce Refl -- Todo: Write proof.

{-# INLINE mappendAssocProof #-}
mappendAssocProof :: MAtom ctx xs -> MList (ctx :++: xs) ys ->  MList (ctx :++: xs :++: ys) zs -> (xs :++: (ys :++: zs)) :~: ((xs :++: ys) :++: zs)
mappendAssocProof _ _ _ = unsafeCoerce Refl -- Todo: Write proof.

{-# INLINE threeMConsAssocProof #-}
threeMConsAssocProof :: MAtom ctx xs -> MAtom (ctx :++: xs) ys -> MAtom (ctx :++: xs :++: ys) zs -> (xs :++: ys :++: zs) :~: (xs :++: (ys :++: zs))
threeMConsAssocProof _ _ _ = unsafeCoerce Refl -- Todo: Write proof.
