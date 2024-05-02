class RedBlackTree:
  root_ /RedBlackNode? := null

  do [block] -> none:
    if root_:
      do_ root_ block

  do_ node/RedBlackNode [block] -> none:
    if node.left_:
      do_ node.left_ block
    block.call node
    if node.right_:
      do_ node.right_ block

  dump -> none:
    if root_:
      dump_ root_ 0

  dump_ node/RedBlackNode depth/int -> none:
    if node.left_:
      dump_ node.left_ (depth + 1)
    color := node.red_ ? "r" : "b"
    print "  " * depth + "$color$node"
    if node.right_:
      dump_ node.right_ (depth + 1)

  add value/RedBlackNode -> none:
    if root_ == null:
      root_ = value
      value.red_ = false
      return 
    value.red_ = true
    insert_ value root_

  insert_ value/RedBlackNode node/RedBlackNode -> none:
    if value < node:
      if node.left_ == null:
        value.parent_ = node
        node.left_ = value
        value.red_ = true
        red-check_ value node
      else:
        insert_ value node.left_
    else:
      if node.right_ == null:
        value.parent_ = node
        node.right_ = value
        value.red_ = true
        red-check_ value node
      else:
        insert_ value node.right_

  red-check_ node/RedBlackNode parent/RedBlackNode? -> none:
    print "red-check_"
    while node != root_:
      if not parent.red_:
        print "  L1"
        // I1.
        return
      gramps := parent.parent_
      if gramps == null:
        // I4.
        parent.red_ = false
        print "  L4"
        return
      index := parent == gramps.left_ ? 0 : 1
      uncle := index == 0 ? gramps.right_ : gramps.left_
      if uncle == null or not uncle.red_:
        // I5 or I6, parent is red, uncle is black.
        sibling := index == 0 ? parent.right_ : parent.left_
        if node == sibling:
          // I5, parent is red, uncle is black node is inner grandchild of gramps.
          rotate_ parent index
          node = parent
          parent = index == 0 ? gramps.left_ : gramps.right_
          // Fall through to I6.
        rotate_ gramps (1 - index)
        parent.red_ = false
        gramps.red_ = true
        return
      else:
        // I2, parent and uncle are red.
        parent.red_ = false
        uncle.red_ = false
        gramps.red_ = true
        node = gramps
        parent = node.parent_
    // I3.

  rotate_ parent/RedBlackNode index/int -> none:
    gramps := parent.parent_
    s := index == 0 ? parent.right_ : parent.left_
    c := index == 0 ? s.left_ : s.right_
    if index == 0:
      parent.right_ = c
    else:
      parent.left_ = c
    if c: c.parent_ = parent
    if index == 0:
      s.left_ = parent
    else:
      s.right_ = parent
    parent.parent_ = s
    s.parent_ = gramps
    if gramps:
      if parent == gramps.right_:
        gramps.right_ = s
      else:
        gramps.left_ = s
    else:
      root_ = s

abstract
class RedBlackNode:
  left_ /any := null
  right_ /any := null
  parent_ /any := null
  red_ /bool := false

  constructor:

  constructor .left_ .right_ .parent_:

  abstract operator < other/RedBlackNode -> bool

