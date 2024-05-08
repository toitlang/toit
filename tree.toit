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

  first -> any:
    do: return it
    throw "empty"

  last -> any:
    do --reversed: return it
    throw "empty"

  clear -> none:
    root_ = null
    size_ = 0

  static LEFT_ ::= 0
  static CENTER_ ::= 1
  static RIGHT_ ::= 2
  static UP_ ::= 3

  do_ node/TreeNode [block] -> none:
    // Avoids recursion because it can go too deep on the splay tree.
    // Also avoids a collection based stack, since we have parent pointers.
    direction := LEFT_
    while true:
      if direction == LEFT_:
        if node.left_:
          node = node.left_
        else:
          direction = CENTER_
      else if direction == CENTER_:
        block.call node
        direction = RIGHT_
      else if direction == RIGHT_:
        if node.right_:
          node = node.right_
          direction = LEFT_
        else:
          direction = UP_
      else if direction == UP_:
        parent := node.parent_
        if not parent: return
        if identical node parent.left_:
          direction = CENTER_
        else:
          direction = UP_
        node = parent

  do-reversed_ node/TreeNode? [block] -> none:
    // Avoids recursion because it can go too deep on the splay tree.
    // Also avoids a collection based stack, since we have parent pointers.
    direction := RIGHT_
    while true:
      if direction == RIGHT_:
        if node.right_:
          node = node.right_
        else:
          direction = CENTER_
      else if direction == CENTER_:
        block.call node
        direction = LEFT_
      else if direction == LEFT_:
        if node.left_:
          node = node.left_
          direction = RIGHT_
        else:
          direction = UP_
      else if direction == UP_:
        parent := node.parent_
        if not parent: return
        if identical node parent.right_:
          direction = CENTER_
        else:
          direction = UP_
        node = parent

  operator == other/NodeTree -> bool:
    return equals_ other: | a b | a.compare-to b

  equals_ other/NodeTree [equality-block] -> bool:
    if other is not NodeTree: return false
    // TODO(florian): we want to be more precise and check for exact class-match?
    if other.size != size: return false
    if size == 0: return true
    // Avoids recursion because it can go too deep on the splay tree.
    // Also avoids doing a log n lookup for each element, which would make
    //   the operation O(log n) instead of linear.
    // Also avoids a collection based stack, since we have parent pointers.
    node1 := root_
    node2 := other.root_
    direction1 := LEFT_
    direction2 := LEFT_
    while true:
      while direction1 != CENTER_:
        if direction1 == LEFT_:
          if node1.left_:
            node1 = node1.left_
          else:
            direction1 = CENTER_
        else if direction1 == RIGHT_:
          if node1.right_:
            node1 = node1.right_
            direction1 = LEFT_
          else:
            direction1 = UP_
        else if direction1 == UP_:
          parent := node1.parent_
          if parent == null: return true
          if identical node1 parent.left_:
            direction1 = CENTER_
          else:
            direction1 = UP_
          node1 = parent
      while direction2 != CENTER_:
        if direction2 == LEFT_:
          if node2.left_:
            node2 = node2.left_
          else:
            direction2 = CENTER_
        else if direction2 == RIGHT_:
          if node2.right_:
            node2 = node2.right_
            direction2 = LEFT_
          else:
            direction2 = UP_
        else if direction2 == UP_:
          parent := node2.parent_
          assert: parent != null
          if identical node2 parent.left_:
            direction2 = CENTER_
          else:
            direction2 = UP_
          node2 = parent
      if not equality-block.call node1 node2: return false
      direction1 = RIGHT_
      direction2 = RIGHT_

  abstract dump -> none

  abstract add value/TreeNode -> none

  /**
  Adds all elements of the given $collection to this instance.
  */
  add-all collection/Collection -> none:
    collection.do: add it

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

class SetSplayNode_ extends SplayNode:
  value_ /Comparable := ?

  constructor .value_:

  compare-to other/SetSplayNode_ -> int:
    return value_.compare-to other.value_

  compare-to other/SetSplayNode_ [--if-equal] -> int:
    return value_.compare-to other.value_ --if-equal=: | self other |
      return if-equal.call self.value_ other.value

/**
A set of keys.
The objects used as keys must be $Comparable and immutable in the sense
  that they do not change their comparison value while they are in the set.
Equality is determined by the compare-to method from $Comparable.
A hash code is not needed for the keys.  Duplicate keys will not be added.
Iteration is in order of the keys.
*/
class SplaySet extends SplayNodeTree:
  /**
  Adds the given $key to this instance.
  If an equal key is already in this instance, it is overwritten by the new one.
  */
  add key/Comparable -> none:
    nearest/SetSplayNode_? := (find_: | node/SetSplayNode_ | key.compare-to node.value_) as any
    if nearest:
      result := key.compare-to nearest.value_
      if result == 0:
        // Equal.  Overwrite.
        nearest.value_ = key
        splay_ nearest
        return
      node := SetSplayNode_ key
      node.parent_ = nearest
      if result < 0:
        nearest.left_ = node
      else:
        nearest.right_ = node
      size_++
      splay_ node
    else:
      root_ = SetSplayNode_ key
      size_ = 1

  do [block] -> none:
    super: block.call it.value_

  do --reversed/bool [block] -> none:
    if not reversed: throw "Argument Error"
    super --reversed: block.call it.value_

  /**
  Whether this instance contains a key equal to the given $key.
  Equality is determined by the compare-to method from $Comparable.
  */
  contains key/Comparable -> bool:
    nearest/SetSplayNode_? := (find_: | node/SetSplayNode_ | key.compare-to node.value_) as any
    if nearest:
      result := key.compare-to nearest.value_
      return result == 0
    return false

  /** Whether this instance contains all elements of $collection. */
  contains-all collection/Collection -> bool:
    collection.do: if not contains it: return false
    return true

  /** Removes all elements of $collection from this instance. */
  remove-all collection/Collection -> none:
    collection.do: remove it --if-absent=: null

  /**
  Removes a key equal to the given $key from this instance.
  Equality is determined by the compare-to method from $Comparable.
  The key does not need to be present.
  */
  remove key/Comparable -> none:
    remove key --if-absent=(: null)

  /**
  Removes a key equal to the given $key from this instance.
  Equality is determined by the compare-to method from $Comparable.
  If the key is absent, calls $if-absent with the given key.
  */
  remove key/Comparable [--if-absent] -> none:
    nearest/SetSplayNode_? := (find_: | node/SetSplayNode_ | key.compare-to node.value_) as any
    if nearest:
      result := key.compare-to nearest.value_
      if result == 0:
        super nearest
      else:
        if-absent.call key

/**
A splay tree which self-adjusts to avoid imbalance on average.
Iteration is in order of the values according to the compare-to method.
This tree can store elements that are subtypes $SplayNode.
See $SplaySet for a version that can store any element.
Implements $Collection.
The nodes should implement $Comparable.  The same node cannot be
  added twice or added to two different trees, but a tree can contain
  two different nodes that are equal according to compare-to method.
To remove a node from the tree, use a reference to the node.
*/
class SplayNodeTree extends NodeTree:
  /**
  Adds a value to this tree.
  The value must not already be in a tree.
  */
  add value/SplayNode -> none:
    assert: value.parent_ == null
    assert: value.left_ == null
    assert: value.right_ == null
    size_++
    if root_ == null:
      root_ = value
      return
    insert_ value (root_ as SplayNode)
    splay_ value

  /**
  Removes the given value from this tree.
  Equality is determined by object identity ($identical).
  The given value must be in this tree.
  */
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

  /**
  Returns either a node that compares equal or a node that is the closest
    parent to a new, correctly placed node.  The block is passed a node and
    should return a negative integer if the new node should be placed to the
    left, 0 if there is an exact match, and a positive integer if the new
    node should be placed to the right.
  If the collection is empty, returns null.
  */
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

  /**
  A debugging method that prints a representation of the tree.
  */
  dump --check=true -> none:
    print "***************************"
    if root_:
      if root_.parent_:
        throw "root_.parent is not null"
      dump_ root_ "" "" "": | parent child |
        if not identical child.parent_ parent:
          throw "child.parent is not parent"

/**
A red-black tree which self-adjusts to avoid imbalance.
Iteration is in order of the values according to the compare-to method.
This tree can store elements that are subtypes $RedBlackNode.
See $RedBlackSet for a version that can store any element.
Implements $Collection.
The nodes should implement $Comparable.  The same node cannot be
  added twice or added to two different trees, but a tree can contain
  two different nodes that are equal according to compare-to method.
To remove a node from the tree, use a reference to the node.
*/
class RedBlackNodeTree extends NodeTree:
  /**
  Adds a value to this tree.
  The value must not already be in a tree.
  */
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
      uncle := grandparent.get_ (1 - index)
      if is-black_ uncle:
        // I5 or I6, parent is red, uncle is black.
        sibling := index == 0 ? parent.right_ : parent.left_
        if identical node sibling:
          // I5, parent is red, uncle is black node is inner grandchild of
          // grandparent.
          rotate_ parent index
          node = parent
          parent = grandparent.get_ index
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
    sibling := parent.get_ (1 - index)
    close := sibling.get_ index  // Close nephew.
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

  /**
  Removes the given value from this tree.
  Equality is determined by object identity ($identical).
  The given value must be in this tree.
  */
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
    sibling := (parent.get_ (1 - index)) as RedBlackNode
    close := sibling.get_ index          // Distant nephew.
    distant := sibling.get_ (1 - index)  // Close nephew.
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
        distant = sibling.get_ (1 - index)
        close = sibling.get_ index
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
          sibling = parent.get_ (1 - index)
          close = sibling.get_ index          // Distant nephew.
          distant = sibling.get_ (1 - index)  // Close nephew.
    // D1 return.

  is-black_ node/RedBlackNode? -> bool:
    return node == null or not node.red_

  leftmost_ node/RedBlackNode -> RedBlackNode:
    while node.left_:
      node = node.left_
    return node

  /**
  A debugging method that prints a representation of the tree.
  */
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

  get_ index/int -> TreeNode?:
    if index == 0:
      return left_
    else:
      assert: index == 1
      return right_

/**
A class that can be specialized to store nodes in a $SplayNodeTree.
*/
abstract
class SplayNode extends TreeNode:

/**
A class that can be specialized to store nodes in a $RedBlackNodeTree.
*/
abstract
class RedBlackNode extends TreeNode:
  red_ /bool := false

  get_ index/int -> RedBlackNode?:
    return (super index) as any
