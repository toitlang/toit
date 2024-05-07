abstract
class Tree extends CollectionBase:
  root_ /TreeNode? := null
  size_ /int := 0

  size -> int:
    return size_

  do [block] -> none:
    if root_:
      do_ root_ block

  do_ node/TreeNode [block] -> none:
    if node.left_:
      do_ node.left_ block
    block.call node
    if node.right_:
      do_ node.right_ block

  abstract dump -> none

  abstract add value/TreeNode -> none

  abstract remove value/TreeNode -> none

  dump_ node/TreeNode left-indent/string self-indent/string right-indent/string [block] -> none:
    if node.left_:
      dump_ node.left_ (left-indent + "  ") (left-indent + "╭─") (left-indent + "│ "):
        if node.left_.parent_ != node:
          throw "node.left_.parent is not node (node=$node, node.left_=$node.left_, node.left_.parent_=$node.left_.parent_)"
      block.call node node.left_
    print self-indent + node.stringify
    if node.right_:
      dump_ node.right_ (right-indent + "│ ") (right-indent + "╰─") (right-indent + "  "):
        if node.right_.parent_ != node:
          throw "node.right_.parent is not node (node=$node, node.right_=$node.right_, node.right_.parent_=$node.right_.parent_)"
      block.call node node.right_

  overwrite-child_ from/TreeNode to/TreeNode? -> none:
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

  overwrite-child_ from/TreeNode to/TreeNode? --parent -> none:
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

class SplayTree extends Tree:
  dump --check=true -> none:
    print "***************************"
    if root_:
      if root_.parent_:
        throw "root_.parent is not null"
      dump_ root_ "" "" "": | parent child |
        if child.parent_ != parent:
          throw "child.parent is not parent"

  add value/SplayNode -> none:
    // The value cannot already be in a tree.
    assert: value.parent_ == null
    assert: value.left_ == null
    assert: value.right_ == null
    size_++
    if root_ == null:
      root_ = value
      return
    insert_ value (root_ as SplayNode)
    splay_ value

  remove value/SplayNode -> none:
    parent := value.parent_
    assert: parent != null or root_ == value
    assert:
      v := value
      while v != root_:
        v = v.parent_
      v == root_  // Assert that the item being removed is in this tree.
    size_--
    if value.left_ == null:
      if value.right_ == null:
        // No children.
        overwrite-child_ value null
      else:
        // Only right child.
        overwrite-child_ value value.right_
    else:
      if value.right_ == null:
        // Only left child.
        overwrite-child_ value value.left_
      else:
        // Both children exist.  Move up the left child to be the new
        // parent.
        replacement := value.left_
        old-right := replacement.right_
        replacement.right_ = value.right_
        value.right_.parent_ = replacement
        overwrite-child_ value replacement
        if old-right:
          insert_ old-right replacement
          splay_ replacement
          return
    value.right_ = null
    value.left_ = null

    if parent:
      splay_ parent

    assert: value.parent_ == null
    assert: value.left_ == null
    assert: value.right_ == null

  insert_ value/SplayNode node/SplayNode -> none:
    if value < node:
      if node.left_ == null:
        value.parent_ = node
        node.left_ = value
      else:
        insert_ value node.left_
    else:
      if node.right_ == null:
        value.parent_ = node
        node.right_ = value
      else:
        insert_ value node.right_

  splay_ node/SplayNode -> none:
    while node.parent_:
      parent := node.parent_
      gramps := parent.parent_
      if gramps == null:
        rotate_ node
      else:
        if node == parent.left_ and parent == gramps.left_:
          rotate_ parent
          rotate_ node
        else if node == parent.right_ and parent == gramps.right_:
          rotate_ parent
          rotate_ node
        else:
          rotate_ node
          rotate_ node

  rotate_ node/SplayNode -> none:
    parent := node.parent_
    if parent == null:
      return
    gramps := parent.parent_
    if gramps:
      if parent == gramps.left_:
        gramps.left_ = node
      else:
        assert: parent == gramps.right_
        gramps.right_ = node
    else:
      root_ = node
    if node == parent.left_:
      parent.left_ = node.right_
      if node.right_:
        node.right_.parent_ = parent
      node.right_ = parent
    else:
      assert: node == parent.right_
      parent.right_ = node.left_
      if node.left_:
        node.left_.parent_ = parent
      node.left_ = parent
    node.parent_ = gramps
    parent.parent_ = node

class RedBlackTree extends Tree:
  dump --check=true -> none:
    print "***************************"
    if root_:
      if root_.parent_:
        throw "root_.parent is not null"
      dump_ root_ "" "" "": | parent child |
        if parent.red_ and child.red_:
          throw "red-red violation"
        if child.parent_ != parent:
          throw "child.parent is not parent"
      if check: check-black-depth_ (root_ as RedBlackNode) [-1] 0

  check-black-depth_ node/RedBlackNode tree-depth/List depth/int -> none:
    if not node.red_:
      depth++
    if (not node.left_ and not node.right_):
      if tree-depth[0] == -1:
        tree-depth[0] = depth
      else:
        if tree-depth[0] != depth:
          throw "black depth mismatch at $node"
    if node.left_:
      check-black-depth_ node.left_ tree-depth depth
    if node.right_:
      check-black-depth_ node.right_ tree-depth depth

  add value/RedBlackNode -> none:
    // The value cannot already be in a tree.
    assert: value.parent_ == null
    assert: value.left_ == null
    assert: value.right_ == null
    size_++
    if root_ == null:
      root_ = value
      value.red_ = false
      return 
    value.red_ = true
    insert_ value (root_ as any)

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
        // I1.
        return
      gramps := parent.parent_
      if gramps == null:
        // I4.
        parent.red_ = false
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

  remove value/RedBlackNode -> none:
    parent := value.parent_
    left := value.left_
    right := value.right_
    assert: parent != null or root_ == value
    assert:
      v := value
      while v != root_:
        v = v.parent_
      v == root_
    size_--
    if left != null and right != null:
      // Both children exist.
      // Replace with leftmost successor.
      successor := leftmost_ right
      successor-parent := successor.parent_
      successor-right := successor.right_
      // Wikipedia says we free leftmost node instead of the value node, but
      // we don't want to mess with object lifetimes, so we patch around it.
      successor.left_ = left
      left.parent_ = successor
      value.left_ = null
      value.right_ = successor-right
      if successor-right:
        successor-right.parent_ = value
      if successor-parent != value:
        successor.right_ = right
        right.parent_ = successor
        overwrite-child_ value successor
        overwrite-child_ successor value --parent=successor-parent
      else:
        // Successor is the right child of value.
        overwrite-child_ value successor
        successor.right_ = value
        value.parent_ = successor
      red := successor.red_
      successor.red_ = value.red_
      value.red_ = red
      size_++  // Don't decrement twice.
      remove value
      return
    else if left != null or right != null:
      // Exactly one of the children is non-null.
      child := ?
      if left:
        child = left
        value.left_ = null
      else:
        assert: right
        child = right
        value.right_ = null
      overwrite-child_ value child
      child.red_ = false
    else:
      assert: left == null and right == null
      // Leaf node.
      index := (not parent or value == parent.left_) ? 0 : 1
      overwrite-child_ value null
      if value != root_ and not value.red_:
        // Leaf node is black - the difficult case.
        delete-check_ value parent index

    assert: value.parent_ == null
    assert: value.left_ == null
    assert: value.right_ == null

  delete-check_ value/RedBlackNode parent/RedBlackNode? index/int -> none:
    if parent == null: return
    sibling := index == 0 ? parent.right_ : parent.left_
    close := index == 0 ? sibling.left_ : sibling.right_    // Distant nephew.
    distant := index == 0 ? sibling.right_ : sibling.left_  // Close nephew.
    while parent != null:  // return on D1
      if sibling.red_:
        // D3.
        assert: not parent.red_
        assert: is-black_ close
        assert: is-black_ distant
        rotate_ parent index
        parent.red_ = true
        sibling.red_ = false
        sibling = close
        distant = index == 0 ? sibling.right_ : sibling.left_
        close = index == 0 ? sibling.left_ : sibling.right_
        // Iterate to go to D6, D5 or D4.
      else if close != null and close.red_:
        // D5.
        rotate_ sibling (1 - index)
        sibling.red_ = true
        close.red_ = false
        distant = sibling
        sibling = close
        // Iterate to go to D6.
      else if distant != null and distant.red_:
        // D6.
        rotate_ parent index
        sibling.red_ = parent.red_
        parent.red_ = false
        distant.red_ = false
        return
      else:
        // D4 and D2
        sibling.red_ = true
        if parent.red_:
          // D4.
          parent.red_ = false
          return
        // D2.  Go up the tree.
        sibling.red_ = true
        value = parent
        parent = value.parent_
        if parent:
          index = value == parent.left_ ? 0 : 1
          sibling = index == 0 ? parent.right_ : parent.left_
          close = index == 0 ? sibling.left_ : sibling.right_    // Distant nephew.
          distant = index == 0 ? sibling.right_ : sibling.left_  // Close nephew.
    // D1 return.

  is-black_ node/RedBlackNode? -> bool:
    return node == null or not node.red_

  leftmost_ node/RedBlackNode -> RedBlackNode:
    while node.left_:
      node = node.left_
    return node

abstract
class TreeNode:
  left_ /any := null
  right_ /any := null
  parent_ /any := null

  abstract operator < other/TreeNode -> bool

abstract
class SplayNode extends TreeNode:

abstract
class RedBlackNode extends TreeNode:
  red_ /bool := false
