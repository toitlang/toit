// Provenance: Ported to Toit from splay.js in the Octane benchmark suite,
// https://github.com/chromium/octane. Keys are integers instead of floats, and
// the sizes are the ones in the original. The original license follows.
//
// Copyright 2009 the V8 project authors. All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
//       copyright notice, this list of conditions and the following
//       disclaimer in the documentation and/or other materials provided
//       with the distribution.
//     * Neither the name of Google Inc. nor the names of its
//       contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

SPLAY-TREE-SIZE ::= 8000
SPLAY-TREE-MODIFICATIONS ::= 80
SPLAY-TREE-PAYLOAD-DEPTH ::= 5
RUNS ::= 300

class Leaf:
  array/List ::= [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
  text/string
  constructor .text:

class Payload:
  left := ?
  right := ?
  constructor .left .right:

generate-payload-tree depth/int tag/string -> any:
  if depth == 0: return Leaf "String for key $tag in leaf node"
  return Payload (generate-payload-tree depth - 1 tag) (generate-payload-tree depth - 1 tag)

class Node:
  key/int
  value/any
  left/Node? := null
  right/Node? := null
  constructor .key .value:

class SplayTree:
  root/Node? := null

  splay key/int -> none:
    if not root: return
    dummy := Node 0 root.value
    left := dummy
    right := dummy
    current/Node := root
    while true:
      if key < current.key:
        next := current.left
        if not next: break
        if key < next.key:
          current.left = next.right
          next.right = current
          current = next
          next = current.left
          if not next: break
        right.left = current
        right = current
        current = next
      else if key > current.key:
        next := current.right
        if not next: break
        if key > next.key:
          current.right = next.left
          next.left = current
          current = next
          next = current.right
          if not next: break
        left.right = current
        left = current
        current = next
      else:
        break
    left.right = current.left
    right.left = current.right
    current.left = dummy.right
    current.right = dummy.left
    root = current

  insert key/int value/any -> none:
    if not root:
      root = Node key value
      return
    splay key
    r/Node := root
    if r.key == key: return
    node := Node key value
    if key > r.key:
      node.left = r
      node.right = r.right
      r.right = null
    else:
      node.right = r
      node.left = r.left
      r.left = null
    root = node

  remove key/int -> none:
    if not root: return
    splay key
    r/Node := root
    if r.key != key: return
    if not r.left:
      root = r.right
    else:
      right := r.right
      root = r.left
      splay key
      root.right = right

  find key/int -> Node?:
    if not root: return null
    splay key
    return root.key == key ? root : null

  find-greatest-less-than key/int -> Node?:
    if not root: return null
    splay key
    r/Node := root
    if r.key < key: return r
    if r.left:
      current/Node := r.left
      while current.right: current = current.right
      return current
    return null

seed := 49734321
next-random -> int:
  seed = ((seed * 1103515245) + 12345) & 0x7fffffff
  return seed

insert-new-node tree/SplayTree -> int:
  key := next-random
  while (tree.find key) != null: key = next-random
  tree.insert key (generate-payload-tree SPLAY-TREE-PAYLOAD-DEPTH "$key")
  return key

main:
  tree := SplayTree
  SPLAY-TREE-SIZE.repeat: insert-new-node tree
  RUNS.repeat:
    SPLAY-TREE-MODIFICATIONS.repeat:
      key := insert-new-node tree
      greatest := tree.find-greatest-less-than key
      tree.remove (greatest ? greatest.key : key)
  count := 0
  stack := [tree.root]
  while not stack.is-empty:
    n/Node? := stack.remove-last
    if n:
      count++
      stack.add n.left
      stack.add n.right
  if count != SPLAY-TREE-SIZE: throw "wrong size"
  print count
