// A block comment glued to a token annotates it and must stay glued —
// including after the last parameter, where it must not drift into the
// body.
foo bar/List/*<int>*/ -> bool:
  return bar.is-empty

baz value/Map/*<string, int>*/ other/int -> int:
  return other

// Detached block comments keep the standard gap.
gee x/int /* detached */ -> int:
  return x
