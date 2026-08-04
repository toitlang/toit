// Copyright (C) 2024 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import .parsers.semantic-version-parser

// TODO(florian): move this to the semver package.

// See https://semver.org/.
class SemanticVersion:
  // Identifiers are [major/int, minor/int, patch/int, (pre-release/int | pre-release/string)*].
  major/int
  minor/int
  patch/int
  pre-releases/List
  build-numbers/List

  static parse version/string -> SemanticVersion:
    return parse version --on-error=: throw "Parse error: $it"

  static parse version/string [--on-error] -> SemanticVersion:
    parsed := (SemanticVersionParser version).semantic-version --consume-all --on-error=on-error
    return SemanticVersion.from-parse-result parsed

  constructor --.major/int --.minor/int=0 --.patch/int=0 --.pre-releases/List=[] --.build-numbers/List=[]:

  constructor.from-parse-result parsed/SemanticVersionParseResult:
    major = parsed.triple.triple[0]
    minor = parsed.triple.triple[1]
    patch = parsed.triple.triple[2]
    pre-releases = parsed.pre-releases
    build-numbers = parsed.build-numbers

  triplet -> List: return [major, minor, patch]

  static compare-lists_ l1/List l2/List [--if-equal]-> int:
    l1.size.repeat:
      if l2.size <= it: return 1
      comparison := l1[it].compare-to l2[it]
      if comparison != 0: return comparison
    if l1.size < l2.size: return -1
    return if-equal.call

  static compare-pre-release-identifiers_ id1 id2 -> int:
    if id1 is int:
      if id2 is not int: return -1
    else if id2 is int:
      return 1
    return id1.compare-to id2

  static compare-pre-releases_ l1/List l2/List [--if-equal] -> int:
    if l1.is-empty:
      return l2.is-empty ? if-equal.call : 1
    if l2.is-empty: return -1

    l1.size.repeat:
      if l2.size <= it: return 1
      comparison := compare-pre-release-identifiers_ l1[it] l2[it]
      if comparison != 0: return comparison
    if l1.size < l2.size: return -1
    return if-equal.call

  operator < other/SemanticVersion -> bool:
    return (compare-to other) < 0

  operator == other/SemanticVersion -> bool:
    return triplet == other.triplet and pre-releases == other.pre-releases

  operator >= other/SemanticVersion:
    return (compare-to other) >= 0

  operator <= other/SemanticVersion -> bool:
    return (compare-to other) <= 0

  operator > other/SemanticVersion -> bool:
    return (compare-to other) > 0

  compare-to other/SemanticVersion -> int:
    return compare-to other --if-equal=: 0

  compare-to other/SemanticVersion [--if-equal] -> int:
    return compare-lists_ triplet other.triplet --if-equal=:
      compare-pre-releases_ pre-releases other.pre-releases --if-equal=if-equal

  to-string -> string:
    str := "$major.$minor.$patch"
    if not pre-releases.is-empty:
      str += "-$(pre-releases.join ".")"
    if not build-numbers.is-empty:
      str += "+$(build-numbers.join ".")"
    return str

  stringify -> string:
    return to-string

  hash-code:
    return major + 1000 * minor + 1000000 * patch

