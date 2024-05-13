import expect show *

import .tree

LAMBDA := :: print "timed out"

main:
  test (: SplayNodeTree): | us/int | SplayTimeout us LAMBDA
  test (: RedBlackNodeTree): | us/int | RBTimeout us LAMBDA
  test2 (: SplayNodeTree) (: | us/int | SplayTimeout us LAMBDA) (: it as SplayTimeout)
  test2 (: RedBlackNodeTree) (: | us/int | RBTimeout us LAMBDA) (: it as RBTimeout)
  test2 --no-identity (: SplaySet) (: | us/int | us) (: it as int)
  test2 --no-identity (: RedBlackSet) (: | us/int | us) (: it as int)
  test-set: SplaySet
  bench false SplayNodeTree "splay": | us/int | SplayTimeout us LAMBDA
  bench false RedBlackNodeTree "red-black": | us/int | RBTimeout us LAMBDA
  bench true SplayNodeTree "splay": | us/int | SplayTimeout us LAMBDA
  bench true RedBlackNodeTree "red-black": | us/int | RBTimeout us LAMBDA

class RBTimeout extends RedBlackNode:
  us /int
  lambda /Lambda

  constructor .us .lambda:

  compare-to other/RBTimeout -> int:
    return us - other.us

  compare-to other/RBTimeout [--if-equal]-> int:
    other-us/int := other.us
    if us == other-us:
      return if-equal.call this other
    return us - other-us

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

  compare-to other/SplayTimeout -> int:
    return us - other.us

  compare-to other/SplayTimeout [--if-equal]-> int:
    other-us/int := other.us
    if us == other-us:
      return if-equal.call this other
    return us - other-us

  stringify -> string:
    return "Timeout-$us"

test [create-tree] [create-item] -> none:

  tree := create-tree.call

  elements := []

  set-random-seed "jdflkjsdlfkjsdl"

  200.repeat: | i |
    t := create-item.call (random 100)
    tree.add t
    elements.add t

  x := 0
  tree.do: | node |
    if node.us < x:
      throw "Error: $node.us < $x"
    x = node.us

  check tree

  cent := create-item.call 100

  tree.add cent

  check tree

  tree.remove cent

  check tree

  print "Tree size is $tree.size"

  elements.do: | e |
    tree.remove e
    check tree

test2 --identity/bool=true [create-tree] [create-item] [verify-item] -> none:
  print "Testing tree equality"
  tree1 := create-tree.call
  tree2 := create-tree.call
  tree3 := create-tree.call
  // Add elements in random order.
  elements1 := List 100: create-item.call it
  shuffle elements1
  // Add elements in sorted order to test for stack overflow.
  elements2 := List 100: create-item.call it
  // Add elements in reverse order to test for stack overflow.
  elements3 := List 100: create-item.call (99 - it)

  // Add elements in two different ways, so we also test add-all.
  elements1.do: tree1.add it
  tree2.add-all elements2
  elements3.do: tree3.add it

  [tree1, tree2, tree3].do: | tree |
    if not identity:
      expect (tree.contains 5)
      expect (tree.contains 10)
      expect (tree.contains-all [0, 99])
      expect (tree.contains-all [tree.first, tree.last])
      tree.remove 42
      tree.remove 84
      tree.remove 103  // Does not exist.
      tree.remove 13 --if-absent=(: throw "Should have 13")
      called := false
      tree.remove 42 --if-absent=(: called = true)
      expect called
      tree.remove-all [7, 8]
    else:
      tree.remove tree.first
      tree.remove tree.last
      tree.remove tree.last
      tree.remove tree.last
      tree.remove tree.last
    expect (tree.contains tree.first)
    expect (tree.contains tree.last)
    verify-item.call tree.first
    verify-item.call tree.last
    tree.any: 
      verify-item.call it
      false
    tree.every:
      verify-item.call it
      true
    prev := null
    tree.do:
      if prev != null:
        expect (prev.compare-to it) < 0
      prev = it
      verify-item.call it
    prev = null
    tree.do --reversed:
      if prev != null:
        expect (prev.compare-to it) > 0
      prev = it
      verify-item.call it
    expect-equals 95 tree.size
    expect (not tree.is-empty)

  expect-equals tree1 tree2
  expect-equals tree1 tree3
  expect-equals tree3 tree2

  [tree1, tree2, tree3].do: | tree |
    tree.clear
    expect (tree.is-empty)

test-set [create-tree] -> none:

shuffle list/List:
  size := list.size
  indeces := List size: it
  dest := List size: it
  size.repeat: | i |
    r := random (size - i)
    dest[i] = list[indeces[r]]
    tmp := indeces[r]
    indeces[r] = indeces[size - i - 1]
    indeces[size - i - 1] = tmp
  list.replace 0 dest

check tree/NodeTree:
  //tree.dump
  i := 0
  tree.do: | node |
    i++
  if i != tree.size:
    throw "Error: $i(i) != $tree.size(tree.size)"
  i = 0
  tree.do --reversed: | node |
    i++
  if i != tree.size:
    throw "Error: $i(i) != $tree.size(tree.size)"

bench one-end/bool tree/NodeTree name/string [create-item] -> none:
  start := Time.monotonic-us
  list := []
  SIZE ::= 100_000
  SIZE.repeat: | i |
    r := random SIZE
    r += (i & 1) * SIZE
    t := create-item.call r
    if r >= SIZE:
      list.add t
    tree.add t

  if one-end:
    while tree.size > 0:
      tree.remove (tree.first)
  else:
    list.do: | t |
      tree.remove t
      tree.remove (tree.first)

  end := Time.monotonic-us
  print "Time $name $(one-end ? "one-end " : " ")for $SIZE elements: $((end - start) / 1000) us"
