// Provenance: Written for this project from the description of the binary-trees task in the
// Computer Language Benchmarks Game, https://benchmarksgame-team.pages.debian.net/.

class Tree:
  left/Tree? := ?
  right/Tree? := ?
  constructor .left .right:
  check -> int:
    l := left
    if not l: return 1
    return 1 + l.check + right.check

make depth/int -> Tree:
  if depth == 0: return Tree null null
  return Tree (make depth - 1) (make depth - 1)

main:
  max := 16
  print (make max + 1).check
  long := make max
  depth := 4
  while depth <= max:
    iterations := 1 << (max - depth + 4)
    total := 0
    iterations.repeat: total += (make depth).check
    print "$iterations $depth $total"
    depth += 4
  print long.check
