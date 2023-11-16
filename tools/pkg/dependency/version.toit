// See https://semver.org/
class SemanticVersion:
  // Identifiers are [major/int, minor/int, patch/int, (pre-release/int | pre-release/string)*]
  major/int
  minor/int
  patch/int
  pre-release/List
  build/List

  constructor version/string:
    parsed := (Parser_ version).semantic-version
    e := catch:
      triplet = (version.split ".").map: int.parse it
    if e:
      throw "Invalid version $version"

  triplet -> List: return [major, minor, patch]

  static compare-lists-less-than_ l1/List l2/List:
    l1.size.repeat:
      if l2.size <= it: return true
      if l1[it] < l2[it]: return true
      if l1[it] > l2[it]: return false
    return false

  operator < other/SemanticVersion -> bool:
    if compare-lists-less-than_ triplet other.triplet: return true
    if compare-lists-less-than_ pre-release other.pre-release: return true
    return false

  operator == other/SemanticVersion -> bool:
    return pre-release == other.pre-release

  operator >= other/SemanticVersion:
    return not this < other


AT-LEAST-CONTRAINT ::= 1
EXACT-CONTRAINT ::= 2

parse-constraint-type_ constraint/string:
    if constraint[0] == '^':
      return AT-LEAST-CONTRAINT
    else if constraint[0] == '=':
      return  EXACT-CONTRAINT
    else: throw "Invalid constraint $constraint"


class VersionConstraint:
  type/int
  version/SemanticVersion

  constructor .version .type:

  constructor constraint/string:
    type = parse-constraint-type_ constraint
    version = SemanticVersion constraint[1..]

  filter versions/List:
    if type == AT-LEAST-CONTRAINT:
      return versions.filter: | v/SemanticVersion | v.major == version.major and v >= version
    if type == EXACT-CONTRAINT:
      return versions.filter: it == versions


class SdkVersion:
  version/SemanticVersion
  stage/int?
  build/int?

  constructor version-string/string:
    if version-string.contains "-":
      minus-split := version-string.split "-"
      version = minus-split[0][1..]
      rest :=: minus-split[1]
      stage-string/string := ?
      if rest.contains ".":
        dot-split := rest.split "."
        stage-string = dot-split[0]
        build = int.parse dot-split[1]
      else:
        stage-string = rest
        build = null

      if stage-string == "alpha":
        stage = 0
      else if stage-string == "beta":
        stage = 1
      else:
        throw "Unrecognized verion stage: $stage-string"
    else:
      stage = null
      build = null
      version = SemanticVersion version-string

  operator < other/SdkVersion -> bool:
    if not version < other.version: return false
    if stage != other.stage:
      if not stage or not other.stage: return false
      if stage >= other.stage: return false
    if build != other.build:
      if not build or not other.build: return false
      if build >= other.build: return false
    return true

  operator == other/SdkVersion -> bool:
    return version == other.version and stage == other.stage and build == other.build

  operator >= other/SemanticVersion:
    return not this < other


class SdkVersionConstraint:
  type/int
  sdk-version/SdkVersion

  constructor constraint/string:
    type = parse-constraint-type_ constraint
    sdk-version = SdkVersion constraint[1..]

  is-satisfied version/SdkVersion -> bool:
    if type == AT-LEAST-CONTRAINT:
      return sdk-version.version.major == version.version.major and sdk-version <= version
    else:
      return version == sdk-version



class ParseResult_:
  children/List
  non-terminal-end/int

  constructor .children .non-terminal-end:

class SemanticVersionParseResult extends ParseResult_:
  constructor triple/TripleParseResult_ pre-releases/List build-numbers/List non-terminal-end/int:
    super [triple, pre-releases, build-numbers] non-terminal-end

class TripleParseResult_ extends ParseResult_:
  constructor major/int minor/int patch/int non-terminal-end/int:
    super [major, minor, patch] non-terminal-end

// Simple LL(k) parser of versions

/*
  A PEG grammar for the semantic version
  semantic-version ::= version-core
                       ('-' pre-releases)?
                       ('+' build-numbers)
  version-core ::= number '.' number '.' number
  pre-releases ::= pre-release ('.' pre-release)*
  build-numbers ::= build-number ('.' build-number)*

  pre-release ::= alphanumeric | numeric
  build-number ::= alphanumeric | digit+

  alphanumeric ::= non-digit identifier-char*
                   | identifier-char non-digit identifier-char*

  identifier-char ::= digit | non-digit

  non-digit ::= '-' | letter
  number ::= '0' | (digit - '0') digit *
  digit ::= [0-9]
  letter := [a-zA-Z]
*/

class Parser_ extends PegParserBase_:
  source/string
  offset/int

  constructor .source/string:
    offset = 0

  current_ -> int: return source[offset]

  lookahead_ k/int -> int?:
    if offset + k >= source.size: return null
    return source[offset + k]

  current-as-error-text_ -> string:
    if not can_consume_: return "end of input"
    return string.from-rune current_

  consume_:
    offset++
    return source[offset - 1]

  can-consume_: return offset < source.size

  end-of-input_: return not can-consume_

  can-match_ char/int:
    return can-consume_ and current_ == char

  can-match_ from/int to/int:
    return can-consume_ and from <= current_ and current_ <= to

  ll-2_ from/int to/int -> :
    return offset + 1 < source.size and from

  match_ char/int -> int?:
    if not can-match_ char: return null
    return consume_

  match_ from/int to/int -> int?:
    if not can-match_ from to: return null
    return consume_

  numeric-identifier_ -> int:
    start := offset
    if match_ '0':
      if can-match_ '1' '9': throw "A numeric identifier can not start with 0 at position $offset"
      return 0

    if not match_ '1' '9': throw "A numeric identifier expceted at position $offset"
    while can-match_ '0' '9': offset++

    return int.parse source[start..offset]

  dot-separated-identifier_ --allow-leading-zero=false -> List:

  expect-match_ char/int -> int:
    if matched := match_ char: return matched
    throw "Parse error, expected $(string.from-rune char) at position $offset, but found $current-as-error-text_"

  semantic-version -> ParseResult_:
    major := numeric-identifier_
    expect-match_ '.'
    minor := numeric-identifier_
    expect-match_ '.'
    patch := numeric-identifier_
    triple := TripleParseResult_ major minor patch offset

    pre-releases := []
    build-numbers := []

    if can-match_ '-':
      consume_
      pre-releases = dot-separated-identifier_

    if can-match_ '+':
      consume_
      build-numbers = dot-separated-identifier_ --allow-leading-zero

    return SemanticVersionParseResult triple pre-releases build-numbers offset
