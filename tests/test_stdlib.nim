import std/unittest

import nfl/compiler

nflModule staticRead("sequence_helpers.nfl"), "tests/sequence_helpers.nfl"

suite "nfl stdlib":
  test "sequence helpers from nfl file":
    check firstValue == 1
    check restValues == @[2'i64, 3, 4]
    check emptyValues == true
    check appendedValues == @[1'i64, 2, 3, 4, 5, 6]

  test "higher-order sequence helpers from nfl file":
    check mappedValues == @[2'i64, 4, 6, 8]
    check mappedWithCapture == @[11'i64, 12, 13, 14]
    check filteredValues == @[1'i64, 2, 3]
    check foldedLeft == -10
    check foldedRight == -2
    check mappedStrings == @[1, 2, 3]
