abstract
class NodeTree extends CollectionBase:
  root_ /TreeNode? := null
  size_ /int := 0

  size -> int:
    return size_

  do [block] -> none:
    if root_:
      do_ root_ block

  do --reversed/bool [block] -> none:
    if reversed != true: throw "Argument Error"
    if root_:
      do-reversed_ root_ block

  first -> TreeNode?:
    do: return it
    throw "empty"

  do_ node/TreeNode? [block] -> none:
    // Avoids recursion because it can go too deep on the splay tree.
    todo := []
    while true:
      if not node:
        if todo.size == 0:
          return
        node = todo.remove-last
        block.call node
        node = node.right_
      else if node.left_:
        todo.add node
        node = node.left_
      else:
        block.call node
        node = node.right_

  do-reversed_ node/TreeNode? [block] -> none:
    // Avoids recursion because it can go too deep on the splay tree.
    todo := []
    while true:
      if not node:
        if todo.size == 0:
          return
        node = todo.remove-last
        block.call node
        node = node.left_
      else if node.right_:
        todo.add node
        node = node.right_
      else:
        block.call node
        node = node.left_

  operator == other/NodeTree -> bool:
    if other is not NodeTree: return false
    // TODO(florian): we want to be more precise and check for exact class-match?
    if other.size != size: return false
    // Avoids recursion because it can go too deep on the splay tree.
    todo := []
    other-todo := []
    node := root_
    other-node := other.root_
    while true:
      if not node:
        if todo.size == 0:
          return false
        node = todo.remove-last
        //block.call node
        node = node.right_
      else if node.left_:
        todo.add node
        node = node.left_
      else:
        //block.call node
        node = node.right_
    return true

  abstract dump -> none

  abstract add value/TreeNode -> none

  abstract remove value/TreeNode -> none

  dump_ node/TreeNode left-indent/string self-indent/string right-indent/string [block] -> none:
    if node.left_:
      dump_ node.left_ (left-indent + "  ") (left-indent + "╭─") (left-indent + "│ "):
        if not identical node.left_.parent_ node:
          throw "node.left_.parent is not node (node=$node, node.left_=$node.left_, node.left_.parent_=$node.left_.parent_)"
      block.call node node.left_
    print self-indent + node.stringify
    if node.right_:
      dump_ node.right_ (right-indent + "│ ") (right-indent + "╰─") (right-indent + "  "):
        if not identical node.right_.parent_ node:
          throw "node.right_.parent is not node (node=$node, node.right_=$node.right_, node.right_.parent_=$node.right_.parent_)"
      block.call node node.right_

  overwrite-child_ from/TreeNode to/TreeNode? -> none:
    parent := from.parent_
    if parent:
      if identical parent.left_ from:
        parent.left_ = to
      else:
        assert: identical parent.right_ from
        parent.right_ = to
    else:
      root_ = to
    if to:
      to.parent_ = parent
    from.parent_ = null

  overwrite-child_ from/TreeNode to/TreeNode? --parent -> none:
    if parent:
      if identical parent.left_ from:
        parent.left_ = to
      else:
        assert: identical parent.right_ from
        parent.right_ = to
    else:
      root_ = to
    if to:
      to.parent_ = parent

class ValueSplayNode_ extends SplayNode:
  value_ /Comparable := ?

  constructor .value_:

  compare-to other/ValueSplayNode_ -> int:
    return value_.compare-to other.value_

  compare-to other/ValueSplayNode_ [--if-equal] -> int:
    return value_.compare-to other.value_ --if-equal=: | self other |
      return if-equal.call self.value_ other.value

class SplayTree extends SplayNodeTree:
  // Adds a value to the tree.
  // If an equal key is already in this instance, it is overwritten by the new
  //   one.
  add value/Comparable -> none:
    nearest/ValueSplayNode_? := (find_: | node/ValueSplayNode_ | value.compare-to node.value_) as any
    if nearest:
      result := value.compare-to nearest.value_
      if result == 0:
        nearest.value_ = value
        splay_ nearest
        return
      node := ValueSplayNode_ value
      node.parent_ = nearest
      if result < 0:
        nearest.left_ = node
      else:
        nearest.right_ = node
      splay_ node
    else:
      root_ = ValueSplayNode_ value

  do [block] -> none:
    do: block.call it.value_

  contains value/Comparable -> bool:
    nearest/ValueSplayNode_? := (find_: | node/ValueSplayNode_ | value.compare-to node.value_) as any
    if nearest:
      result := value.compare-to nearest.value_
      return result == 0
    return false

  remove value/Comparable -> none:
    remove value --if-absent=(: null)

  remove value/Comparable [--if-absent] -> none:
    nearest/ValueSplayNode_? := (find_: | node/ValueSplayNode_ | value.compare-to node.value_) as any
    if nearest:
      result := value.compare-to nearest.value_
      if result == 0:
        super nearest
      else:
        if-absent.call value

/**
A splay tree which self-adjusts to avoid imbalance on average.
This tree can store elements that are subtypes $SplayNode.
See $SplayTree for a version that can store any element.
Implements $Collection.
The nodes should implement $Comparable.  The same node cannot be
  added twice or added to two different trees, but a tree can contain
  two different nodes that are equal according to the == operator.
To remove a node from the tree, use a reference to the node.
*/
class SplayNodeTree extends NodeTree:
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
    assert: parent != null or (identical root_ value)
    assert:
      v := value
      while not identical v root_:
        v = v.parent_
      identical v root_  // Assert that the item being removed is in this tree.
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
    while true:
      if (value.compare-to node) < 0:
        if node.left_ == null:
          value.parent_ = node
          node.left_ = value
          return
        node = node.left_
      else:
        if node.right_ == null:
          value.parent_ = node
          node.right_ = value
          return
        node = node.right_

  // Returns either a node that compares equal or a node that is the closest
  //   parent to a new, correctly placed node.  The block is passed a node and
  //   should return a negative integer if the new node should be placed to the
  //   left, 0 if there is an exact match, and a positive integer if the new
  //   node should be placed to the right.
  // If the collection is empty, returns null.
  find_ [compare] -> SplayNode?:
    node/SplayNode? := root_ as any
    while node:
      if (compare.call node) < 0:
        if node.left_ == null:
          return node
        node = node.left_
      else if (compare.call node) > 0:
        if node.right_ == null:
          return node
        node = node.right_
      else:
        return node
    return null

  splay_ node/SplayNode -> none:
    while node.parent_:
      parent := node.parent_
      grandparent := parent.parent_
      if grandparent == null:
        rotate_ node
      else:
        if ((identical node parent.left_) and (identical parent grandparent.left_)) or
           ((identical node parent.right_) and (identical parent grandparent.right_)):
          rotate_ parent
          rotate_ node
        else:
          rotate_ node
          rotate_ node

  rotate_ node/SplayNode -> none:
    parent := node.parent_
    if parent == null:
      return
    grandparent := parent.parent_
    if grandparent:
      if identical parent grandparent.left_:
        grandparent.left_ = node
      else:
        assert: identical parent grandparent.right_
        grandparent.right_ = node
    else:
      root_ = node
    if identical node parent.left_:
      parent.left_ = node.right_
      if node.right_:
        node.right_.parent_ = parent
      node.right_ = parent
    else:
      assert: identical node parent.right_
      parent.right_ = node.left_
      if node.left_:
        node.left_.parent_ = parent
      node.left_ = parent
    node.parent_ = grandparent
    parent.parent_ = node

  dump --check=true -> none:
    print "***************************"
    if root_:
      if root_.parent_:
        throw "root_.parent is not null"
      dump_ root_ "" "" "": | parent child |
        if not identical child.parent_ parent:
          throw "child.parent is not parent"

class RedBlackNodeTree extends NodeTree:
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
    while true:
      if (value.compare-to node) < 0:
        if node.left_ == null:
          value.parent_ = node
          node.left_ = value
          value.red_ = true
          add-fix-invariants_ value node
          return
        node = node.left_
      else:
        if node.right_ == null:
          value.parent_ = node
          node.right_ = value
          value.red_ = true
          add-fix-invariants_ value node
          return
        node = node.right_

  add-fix-invariants_ node/RedBlackNode parent/RedBlackNode? -> none:
    while not identical node root_:
      if not parent.red_:
        // I1.
        return
      grandparent := parent.parent_
      if grandparent == null:
        // I4.
        parent.red_ = false
        return
      index := (identical parent grandparent.left_) ? 0 : 1
      uncle := grandparent[1 - index]
      if is-black_ uncle:
        // I5 or I6, parent is red, uncle is black.
        sibling := index == 0 ? parent.right_ : parent.left_
        if identical node sibling:
          // I5, parent is red, uncle is black node is inner grandchild of
          // grandparent.
          rotate_ parent index
          node = parent
          parent = grandparent[index]
          // Fall through to I6.
        rotate_ grandparent (1 - index)
        parent.red_ = false
        grandparent.red_ = true
        return
      else:
        // I2, parent and uncle are red.
        parent.red_ = false
        uncle.red_ = false
        grandparent.red_ = true
        node = grandparent
        parent = node.parent_
    // I3.

  rotate_ parent/RedBlackNode index/int -> none:
    grandparent := parent.parent_
    sibling := parent[1 - index]
    close := sibling[index]  // Close nephew.
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
    sibling.parent_ = grandparent
    if grandparent:
      if identical parent grandparent.right_:
        grandparent.right_ = sibling
      else:
        grandparent.left_ = sibling
    else:
      root_ = sibling

  remove value/RedBlackNode -> none:
    parent := value.parent_
    left := value.left_
    right := value.right_
    assert: parent != null or identical root_ value
    assert:
      v := value
      while not identical v root_:
        v = v.parent_
      identical v root_
    size_--
    if left == null:
      if right == null:
        // Leaf node.
        index := (not parent or (identical value parent.left_)) ? 0 : 1
        overwrite-child_ value null
        if (not identical value root_) and not value.red_:
          // Leaf node is black - the difficult case.
          remove-fix-invariants_ value parent index
      else:
        // Only right child.
        child := right
        value.right_ = null
        overwrite-child_ value child
        child.red_ = false
    else:
      if right == null:
        // Only left child.
        child := left
        value.left_ = null
        overwrite-child_ value child
        child.red_ = false
      else:
        // Both children exist.
        // Replace with leftmost successor.
        successor := leftmost_ right
        successor-parent := successor.parent_
        successor-right := successor.right_
        // Wikipedia says we swap the payloads, then free the leftmost node
        // instead of the value node, but this version doesn't change object
        // identities, so we move the nodes in the tree.
        successor.left_ = left
        left.parent_ = successor
        value.left_ = null
        value.right_ = successor-right
        if successor-right:
          successor-right.parent_ = value
        if not identical successor-parent value:
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
        remove value  // After moving the nodes, call the method again.

    assert: value.parent_ == null
    assert: value.left_ == null
    assert: value.right_ == null

  remove-fix-invariants_ value/RedBlackNode parent/RedBlackNode? index/int -> none:
    if parent == null: return
    sibling := parent[1 - index] as RedBlackNode
    close := sibling[index]        // Distant nephew.
    distant := sibling[1 - index]  // Close nephew.
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
        distant = sibling[1 - index]
        close = sibling[index]
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
          index = (identical value parent.left_) ? 0 : 1
          sibling = parent[1 - index]
          close = sibling[index]        // Distant nephew.
          distant = sibling[1 - index]  // Close nephew.
    // D1 return.

  is-black_ node/RedBlackNode? -> bool:
    return node == null or not node.red_

  leftmost_ node/RedBlackNode -> RedBlackNode:
    while node.left_:
      node = node.left_
    return node

  dump --check=true -> none:
    print "***************************"
    if root_:
      if root_.parent_:
        throw "root_.parent is not null"
      dump_ root_ "" "" "": | parent child |
        if parent.red_ and child.red_:
          throw "red-red violation"
        if not identical child.parent_ parent:
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

abstract
class TreeNode implements Comparable:
  left_ /any := null
  right_ /any := null
  parent_ /any := null

  abstract compare-to other/TreeNode -> int
  abstract compare-to other/TreeNode [--if-equal] -> int

  operator [] index/int -> TreeNode?:
    if index == 0:
      return left_
    else:
      assert: index == 1
      return right_

abstract
class SplayNode extends TreeNode:

abstract
class RedBlackNode extends TreeNode:
  red_ /bool := false

  operator [] index/int -> RedBlackNode?:
    return (super index) as any
