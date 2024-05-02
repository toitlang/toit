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
    print "***************************"
    if root_.parent_:
      throw "root_.parent is not null"
    if root_:
      dump_ root_ 0

  dump_ node/RedBlackNode depth/int -> none:
    if node.left_:
      dump_ node.left_ (depth + 1)
      if node.left_.parent_ != node:
        throw "node.left_.parent is not node"
      if node.red_ and node.left_.red_:
        throw "red-red violation"
    color := node.red_ ? "r" : "b"
    print "  " * depth + "$color$node"
    if node.right_:
      dump_ node.right_ (depth + 1)
      if node.right_.parent_ != node:
        throw "node.right_.parent is not node"
      if node.red_ and node.right_.red_:
        throw "red-red violation"

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
        insert-check_ value node
      else:
        insert_ value node.left_
    else:
      if node.right_ == null:
        value.parent_ = node
        node.right_ = value
        value.red_ = true
        insert-check_ value node
      else:
        insert_ value node.right_

  insert-check_ node/RedBlackNode parent/RedBlackNode? -> none:
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
      if is-black_ uncle:
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
    sibling := index == 0 ? parent.right_ : parent.left_
    close := index == 0 ? sibling.left_ : sibling.right_  // Close nephew.
    if index == 0:
      parent.right_ = close
    else:
      parent.left_ = close
    if close: close.parent_ = parent
    if index == 0:
      sibling.left_ = parent
    else:
      sibling.right_ = parent
    parent.parent_ = sibling
    sibling.parent_ = gramps
    if gramps:
      if parent == gramps.right_:
        gramps.right_ = sibling
      else:
        gramps.left_ = sibling
    else:
      root_ = sibling

  delete value/RedBlackNode -> none:
    parent := value.parent_
    if value.left_ != null and value.right_ != null:
      // Both children exist.
      // Replace with leftmost successor.
      successor := leftmost_ value.right_
      overwrite-child_ successor null
      overwrite-child_ value successor
    else if value.left_ != null or value.right_ != null:
      // Exactly one of the children is non-null.
      child := ?
      if value.left_:
        child = value.left_
        value.left_ = null
      else:
        assert: value.right_
        child = value.right_
        value.right_ = null
      overwrite_child_ value child
      child.red_ = false
    else:
      assert: value.left_ == null and value.right_ == null
      // Leaf node.
      index := (not parent or value == parent.left_) ? 0 : 1
      overwrite_child_ value null
      if value != root_ and not value.red_:
        // Leaf node is black - the difficult case.
        delete-check_ value parent index

    assert: value.parent_ == null
    assert: value.left_ == null
    assert: value.right_ == null

  delete-check_ value/RedBlackNode parent/RedBlackNode index/int -> none:
    while value != root_:
      sibling := index == 0 ? parent.right_ : parent.left_
      distant := index == 0 ? sibling.right_ : sibling.left_  // Close nephew.
      close := index == 0 ? sibling.left_ : sibling.right_    // Distant nephew.
      if sibling.red_:
        // D3.
        assert: parent.red_
        assert: is-black_ close
        assert: is-black_ distant
        unreachable
      else if distant and distant.red_:
        // D6.
        unreachable
      else if close and close.red_:
        // D5.
        unreachable
      else:
        // D4 and D2
        sibling.red_ = true
        if parent.red_:
          // D4.
          parent.red_ = false
          return
        // D2.  Got up the tree.
        value = parent
        parent = value.parent_
        index = value == parent.left_ ? 0 : 1
    // D1.  Return.

  is-black_ node/RedBlackNode? -> bool:
    return node == null or not node.red_

  overwrite_child_ from/RedBlackNode to/RedBlackNode? -> none:
    parent := from.parent_
    if parent:
      if parent.left_ == from:
        parent.left_ = to
      else:
        assert: parent.right_ == from
        parent.right_ = to
    else:
      root_ = to
    if to:
      to.parent_ = parent
    from.parent_ = null

  leftmost_ node/RedBlackNode -> RedBlackNode:
    while node.left_:
      node = node.left_
    return node

abstract
class RedBlackNode:
  left_ /any := null
  right_ /any := null
  parent_ /any := null
  red_ /bool := false

  constructor:

  constructor .left_ .right_ .parent_:

  abstract operator < other/RedBlackNode -> bool

