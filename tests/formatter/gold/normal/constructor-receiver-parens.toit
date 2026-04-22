// Toit naming convention: CamelCase (uppercase first letter) names are
// classes. When one appears as a Dot / Index / IndexSlice receiver, the
// formatter wraps it in parens so the instance invocation reads
// explicitly — `(Point).foo` rather than `Point.foo` (which would look
// like a static-member access).

class Point:
  foo: return 42

get-pos: return 0
local-var := 7

main:
  // Uppercase receiver: formatter adds parens.
  a := (Point).foo

  // Uppercase with brackets: parens added.
  b := (Point)[0]

  // Already parenthesised: preserved as-is.
  c := (Point).foo

  // Lowercase receiver: no parens added.
  d := get-pos.x
  e := local-var.x
