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
    parsed := (SemanticVersionParser version).semantic-version --consume-all
    return SemanticVersion.from-parse-result parsed

  constructor --.major/int --.minor/int=0 --.patch/int=0 --.pre-releases/List=[] --.build-numbers/List=[]:

  constructor.from-parse-result parsed/SemanticVersionParseResult:
    major = parsed.triple.triple[0]
    minor = parsed.triple.triple[1]
    patch = parsed.triple.triple[2]
    pre-releases = parsed.pre-releases
    build-numbers = parsed.build-numbers

  triplet -> List: return [major, minor, patch]

  static compare-lists-less-than_ l1/List l2/List:
    l1.size.repeat:
      if l2.size <= it: return true
      if l1[it] < l2[it]: return true
      if l1[it] > l2[it]: return false
    return false

  operator < other/SemanticVersion -> bool:
    if compare-lists-less-than_ triplet other.triplet: return true
    if compare-lists-less-than_ pre-releases other.pre-releases: return true
    return false

  operator == other/SemanticVersion -> bool:
    return triplet == other.triplet and pre-releases == other.pre-releases

  operator >= other/SemanticVersion:
    return not this < other

  operator <= other/SemanticVersion -> bool:
    return this < other or this == other

  operator > other/SemanticVersion -> bool:
    return not this <= other

  stringify -> string:
    str := "$major.$minor.$patch"
    if not pre-releases.is-empty:
      str += "-$(pre-releases.join ".")"
    if not build-numbers.is-empty:
      str += "+$(build-numbers.join ".")"
    return str

  hash-code:
    return major + 1000 * minor + 1000000 * patch


