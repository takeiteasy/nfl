import std/unittest

import nfl/compiler

nflModule staticRead("sequence_helpers.nfl"), "tests/sequence_helpers.nfl"
nflModule staticRead("clos.nfl"), "tests/clos.nfl"

suite "nfl stdlib":
  test "sequence helpers from nfl file":
    check firstValue == 1
    check restValues == @[2, 3, 4]
    check emptyValues == true
    check appendedValues == @[1, 2, 3, 4, 5, 6]

  test "higher-order sequence helpers from nfl file":
    check mappedValues == @[2, 4, 6, 8]
    check mappedWithCapture == @[11, 12, 13, 14]
    check filteredValues == @[1, 2, 3]
    check foldedLeft == -10
    check foldedRight == -2
    check mappedStrings == @[1, 2, 3]

  test "CL-style sequence functions from nfl file":
    check madeArray == @[9, 9, 9]
    check lengthValue == 4
    check reversedValues == @[4, 3, 2, 1]
    check sortedValues == @[1, 1, 3, 4, 5]
    check mapcarValues == @[3, 6, 9, 12]
    check reducedValue == 10
    check removedIfValues == @[3, 4]
    check removedIfNotValues == @[1, 2]
    check countIfValue == 2
    check someValue == true
    check everyValue == true
    check positionValue == 2
    check eltValue == 2
    check arefValue == 2
    check subseqValue == @[2, 3]
    check subseqToEndValue == @[3, 4]

  test "CLOS-lite defclass/make-instance from nfl file (#66)":
    check rexName == "Rex"
    check rexBreed == "corgi"
    check rexSpeaks == "woof"
    check genericSpeaks == "..."

  test ":accessor's generated setter assigns through set! (#75)":
    check rexRenamed == "Fido"

  test ":initform fills an omitted slot with a non-zero default, incl. an inherited slot (#78)":
    check whiskersName == "Whiskers"
    check whiskersSound == "meow"
    check whiskersLives == 9

  test "an explicit make-instance argument still overrides its :initform (#78)":
    check tomSound == "hiss"
    check tomLives == 1

  test ":initarg resolves an inherited slot, alongside the raw field name (#85)":
    check fidoName == "Fido"
    check fidoBreed == "corgi"
    check buddyName == "Buddy"
    check buddyBreed == "lab"

  test ":initarg composes with :initform (#85)":
    check tweetySong == "tweet"
    check robinSong == "chirp"
