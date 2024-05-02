import .red-black

class RBTimeout extends RedBlackNode:
  us /int
  lambda /Lambda

  constructor .us .lambda:

  operator < other/RBTimeout -> bool:
    return us < other.us

  stringify -> string:
    color := red_ ? "r" : "b"
    return "$(color)Timeout-$us"

class SplayTimeout extends TreeNode:
  us /int
  lambda /Lambda

  constructor .us .lambda:

  operator < other/SplayTimeout -> bool:
    return us < other.us

  stringify -> string:
    return "Timeout-$us"

main:
  test RedBlackTree: | us/int lambda/Lambda | RBTimeout us lambda
  test SplayTree: | us/int lambda/Lambda | SplayTimeout us lambda

test tree/Tree [create-timeout] -> none:

  elements := []

  100.repeat: | i |
    t := create-timeout.call (random i)::
        print "Timed out"
    tree.add t
    elements.add t

  x := 0
  tree.do: | node |
    if node.us < x:
      throw "Error: $node.us < $x"
    x = node.us

  tree.dump

  cent := create-timeout.call 100::
    print "Timed out"

  tree.add cent

  tree.dump

  tree.delete cent

  tree.dump

  elements.do: | e |
    print "Removing $e"
    tree.delete e
    tree.dump
