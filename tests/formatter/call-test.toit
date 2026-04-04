foo x y:
  return x + y

bar x y z:
  return x

baz x [block]:
  return block.call x

main:
  // Multi-line call that fits on one line should be flattened.
  a := foo
    1
    2
  // Already on one line — no change.
  b := foo 1 2
  // Block arg should NOT be flattened.
  c := baz
    1: it + 2
  // Long call should break with args on separate lines.
  d := bar
    "a very long string argument that is number one here"
    "a very long string argument that is number two here"
    "a very long string argument that is number three here"
