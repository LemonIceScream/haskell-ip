import Test.DocTest

main :: IO ()
main = doctest
  [ "src/Net/IPv4.hs"
  , "src/Net/IPv4/Range.hs"
  ]
