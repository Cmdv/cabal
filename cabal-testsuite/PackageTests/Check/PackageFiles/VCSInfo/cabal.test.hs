import Test.Cabal.Prelude

-- Missing VCS info.
main = cabalTest $
  fails $ cabal "check" []
