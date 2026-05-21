import std/unittest

import nimp/compiler

nimpModule staticRead("sequence_helpers.nimp"), "tests/stdlib/sequence_helpers.nimp"

suite "nimp stdlib":
  test "sequence helpers from nimp file":
    check firstValue == 1
    check restValues == @[2'i64, 3, 4]
    check emptyValues == true
    check appendedValues == @[1'i64, 2, 3, 4, 5, 6]

  test "higher-order sequence helpers from nimp file":
    check mappedValues == @[2'i64, 4, 6, 8]
    check mappedWithCapture == @[11'i64, 12, 13, 14]
    check filteredValues == @[1'i64, 2, 3]
    check foldedLeft == -10
    check foldedRight == -2
    check mappedStrings == @[1, 2, 3]
