import .tree

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

main:
  test SplayTree: | us/int lambda/Lambda | SplayTimeout us lambda
  test RedBlackTree: | us/int lambda/Lambda | RBTimeout us lambda

test tree/Tree [create-timeout] -> none:

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

check tree/Tree:
  tree.dump
  i := 0
  tree.do: | node |
    i++
  if i != tree.size:
    throw "Error: $i(i) != $tree.size(tree.size)"
