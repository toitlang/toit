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
  //test SplayTree: | us/int lambda/Lambda | SplayTimeout us lambda
  test RedBlackTree: | us/int lambda/Lambda | RBTimeout us lambda

test tree/Tree [create-timeout] -> none:

  elements := []

  set-random-seed "jdflkjsdlfkjsdl"

  200.repeat: | i |
    t := create-timeout.call (random 100)::
        print "Timed out"
    tree.add t
    elements.add t

  x := 0
  tree.do: | node |
    if node.us < x:
      throw "Error: $node.us < $x"
    x = node.us

  print "Dumping 1"
  tree.dump

  cent := create-timeout.call 100::
    print "Timed out"

  tree.add cent

  print "Dumping 2"
  tree.dump

  tree.delete cent

  print "Dumping 3"
  tree.dump

  elements.do: | e |
    print "Removing xx $e"
    tree.delete e
    tree.dump
