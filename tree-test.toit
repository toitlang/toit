import .tree

main:
  test SplayNodeTree: | us/int lambda/Lambda | SplayTimeout us lambda
  test RedBlackNodeTree: | us/int lambda/Lambda | RBTimeout us lambda
  bench false SplayNodeTree "splay": | us/int lambda/Lambda | SplayTimeout us lambda
  bench false RedBlackNodeTree "red-black": | us/int lambda/Lambda | RBTimeout us lambda
  bench true SplayNodeTree "splay": | us/int lambda/Lambda | SplayTimeout us lambda
  bench true RedBlackNodeTree "red-black": | us/int lambda/Lambda | RBTimeout us lambda

class RBTimeout extends RedBlackNode:
  us /int
  lambda /Lambda

  constructor .us .lambda:

  operator < other/RBTimeout -> bool:
    return us < other.us

  stringify -> string:
    RESET := "\x1b[0m"
    RED := "\x1b[31m"
    BLACK := "\x1b[30m"
    color := red_ ? "$RED⬤ r-$RESET" : "$(BLACK)⬤ b-$RESET"
    return "$(color)Timeout-$us"

class SplayTimeout extends SplayNode:
  us /int
  lambda /Lambda

  constructor .us .lambda:

  operator < other/SplayTimeout -> bool:
    return us < other.us

  stringify -> string:
    return "Timeout-$us"

test tree/NodeTree [create-timeout] -> none:

  elements := []

  set-random-seed "jdflkjsdlfkjsdl"

  200.repeat: | i |
    t := create-timeout.call (random 100)::
        print "Timed out"
    print "Adding $t"
    tree.add t
    elements.add t

  x := 0
  tree.do: | node |
    if node.us < x:
      throw "Error: $node.us < $x"
    x = node.us

  check tree

  cent := create-timeout.call 100::
    print "Timed out"

  tree.add cent

  check tree

  tree.remove cent

  check tree

  print "Tree size is $tree.size"

  elements.do: | e |
    print "Removing $e"
    tree.remove e
    check tree

check tree/NodeTree:
  tree.dump
  i := 0
  tree.do: | node |
    i++
  if i != tree.size:
    throw "Error: $i(i) != $tree.size(tree.size)"

bench one-end/bool tree/NodeTree name/string [create-timeout] -> none:
  start := Time.monotonic-us
  list := []
  SIZE ::= 100_000
  SIZE.repeat: | i |
    r := random SIZE
    r += (i & 1) * SIZE
    t := create-timeout.call r::
        print "Timed out"
    if r >= SIZE:
      list.add t
    tree.add t

  if one-end:
    while tree.size > 0:
      tree.remove (tree.first)
  else:
    list.do: | t |
      tree.remove t
      tree.remove (tree.first)

  end := Time.monotonic-us
  print "Time $name $(one-end ? "one-end " : " ")for $SIZE elements: $((end - start) / 1000) us"
