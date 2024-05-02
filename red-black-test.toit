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

  tree.add
      Timeout 1000::
        print "Timed out"

  print "added 1000"

  tree.dump

  tree.add
      Timeout 999::
        print "Timed out"
  
  print "added 999"
  tree.dump

  tree.add
      Timeout 1001::
        print "Timed out"
  
  print "added 1001"
  tree.dump

  10.repeat: | i |
    print "Adding $(i * 1000)"
    tree.add
        Timeout i * 1000::
          print "Timed out"

  tree.dump

  100.repeat: | i |
    print "Adding $i"
    tree.add
        Timeout i::
          print "Timed out"

  tree.dump
