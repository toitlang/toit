// A parenthesized identifier path in receiver position changes static or
// constructor lookup into instance-member lookup on the resulting class
// object. The formatter preserves that semantic distinction for paths through
// a package prefix and named constructor.

class Point:
  foo: return 42

get-pos: return 0
local-var := 7

main:
  // Source-bare: stays bare. Could be a static call or a named
  // constructor; either way, formatter doesn't add parens.
  a := Point.foo

  // Source-bare with brackets: stays bare.
  b := Point[0]

  // Author-parenthesised: preserved.
  c := (Point).foo

  // Package-prefixed and named-constructor paths are preserved too.
  f := (pkg.Point).foo
  g := (pkg.Point.named).foo

  // Lowercase receiver: never gets parens added.
  d := get-pos.x
  e := local-var.x
