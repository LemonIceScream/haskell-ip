{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module ArbitraryInstances where

-- Orphan instances that are needed to make QuickCheck work.

import Net.Types (IPv4(..),IPv4Range(..),Mac(..))
import Test.QuickCheck (Arbitrary(..))

deriving instance Arbitrary IPv4

-- This instance can generate masks that exceed the recommended
-- length of 32.
instance Arbitrary IPv4Range where
  arbitrary = fmap fromTuple arbitrary
    where fromTuple (a,b) = IPv4Range a b

instance Arbitrary Mac where
  arbitrary = fmap fromTuple arbitrary
    where fromTuple (a,b) = Mac a b

instance Arbitrary MacCodec where
  arbitrary = MacCodec <$> arbitrary <*> arbitrary

instance Arbitrary MacGrouping where
  arbitrary = oneof
    [ MacGroupingPairs <$> arbitraryMacSeparator
    , MacGroupingTriples <$> arbitraryMacSeparator
    , MacGroupingQuadruples <$> arbitraryMacSeparator
    , pure MacGroupingNoSeparator
    ]

arbitraryMacSeparator :: Gen Char
arbitraryMacSeparator = oneof [':','-','.','_']

