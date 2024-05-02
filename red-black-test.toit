import .red-black

class Timeout extends RedBlackNode:
  us /int
  lambda /Lambda

  constructor .us .lambda:

  operator < other/Timeout -> bool:
    return us < other.us

  stringify -> string:
    return "Timeout-$us"

main:
  tree := RedBlackTree

  elements := []

  100.repeat: | i |
    t := Timeout (random i)::
        print "Timed out"
    tree.add t
    elements.add t

  x := 0
  tree.do: | node |
    if node.us < x:
      throw "Error: $node.us < $x"
    x = node.us

  tree.dump

  cent := Timeout 100::
    print "Timed out"

  tree.add cent

  tree.dump

  tree.delete cent

  tree.dump

  elements.do: | e |
    print "Removing $e"
    tree.delete e
    tree.dump
