// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Tests maps and sets in which keys are added and removed again: the
// contents and the iteration order after churn, that the index isn't
// rebuilt all the time, that an emptied collection releases its memory, and
// a randomized comparison with a simple reference implementation.

main:
  test-empty-churn
  [1, 2, 3, 4, 5, 6, 7, 8, 13, 14, 27, 100].do: | n |
    test-steady-churn n --fifo
    test-steady-churn n --no-fifo
  test-same-key-churn
  test-rebuild-frequency
  test-emptied-memory
  test-unequal-keys
  test-random

/// Adds and removes one key at a time, as RPC call ids are.
test-empty-churn:
  map := {:}
  set := {}
  1000.repeat:
    map[it] = it * 2
    set.add it
    expect-equals 1 map.size
    expect-equals 1 set.size
    expect-equals it * 2 map[it]
    expect (set.contains it)
    expect-equals [it] map.keys
    expect-equals [it] set.to-list
    map.remove it
    set.remove it
    expect map.is-empty
    expect set.is-empty
    expect-not (map.contains it)
    expect-not (set.contains it)
    expect-equals [] map.keys
    expect-equals "{:}" map.stringify
    expect-null map.index_
    expect-null set.index_
  // Grow from an emptied map.
  10.repeat: map[it] = it
  expect-equals [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] map.keys

/// A map of $n keys in which a new key is added and the oldest ($fifo) or
///   newest key is removed.
test-steady-churn n/int --fifo/bool:
  map := {:}
  set := {}
  keys := []  // Insertion order.
  n.repeat:
    map[it] = -it
    set.add it
    keys.add it
  next := n
  300.repeat:
    map[next] = -next
    set.add next
    if fifo:
      oldest := keys[0]
      keys = keys[1..].copy
      keys.add next
      map.remove oldest
      set.remove oldest
    else:
      map.remove next
      set.remove next
    next++
    expect-equals keys map.keys
    expect-equals keys set.to-list
    expect-equals (keys.map: -it) map.values
    if keys.size > 0:
      expect-equals keys.first map.first
      expect-equals keys.last set.last
      reversed := []
      map.do --reversed: | k v | reversed.add k
      expected-reversed := []
      keys.do --reversed: expected-reversed.add it
      expect-equals expected-reversed reversed
  keys.do: expect-equals -it map[it]
  expect-not (map.contains next - 1 - n)

/// Adds and removes the same key while another key stays.
test-same-key-churn:
  map := {"stay": 0}
  1000.repeat:
    map["churn"] = it
    expect-equals ["stay", "churn"] map.keys
    map.remove "churn"
    expect-equals ["stay"] map.keys
  expect-equals 1 map.size

/// Counts how often the index is replaced during churn.  Before the rebuild
///   rules took the slots of deleted entries into account, maps of one to
///   eight keys rebuilt their index every one to four operations.
test-rebuild-frequency:
  [0, 1, 2, 8, 100].do: | n |
    map := {:}
    n.repeat: map[it] = it
    rebuilds := 0
    index := map.index_
    pairs := 1000
    pairs.repeat:
      map[n + it] = it
      if not identical index map.index_: rebuilds++
      index = map.index_
      map.remove it
      if not identical index map.index_: rebuilds++
      index = map.index_
    if n == 0:
      expect-equals 0 rebuilds
    else:
      // At most one rebuild every three add-remove pairs.
      expect rebuilds * 3 <= pairs

/// A collection that grew and then became empty doesn't keep its backing or
///   index.
test-emptied-memory:
  map := {:}
  set := {}
  10_000.repeat:
    map[it] = it
    set.add it
  10_000.repeat:
    map.remove it
    set.remove it
  expect-null map.index_
  expect-null map.backing_
  expect-null set.index_
  expect-null set.backing_
  // While shrinking, the backing never holds many more deleted positions
  // than entries.
  10_000.repeat: map[it] = it
  9_990.repeat:
    map.remove it
    expect map.backing_.size <= 2 * (2 * map.size + 5)
  expect-equals 10 map.size
  expect map.index_.size <= 32
  // A small map keeps its backing when it becomes empty.
  small := {:}
  small["a"] = 1
  backing := small.backing_
  small.remove "a"
  small["b"] = 2
  expect (identical backing small.backing_)
  expect-equals ["b"] small.keys

/**
Checks that every slot of the index of the $collection (a map if $step is 2,
  a set if 1) refers to a position in the backing, and that a slot that refers
  to an entry has the bits of the entry's hash code.
*/
check-index collection step/int -> none:
  index := collection.index_
  if not index: return
  backing := collection.backing_
  index.do: | slot |
    if slot != 0:
      position := (slot >> 12) - 1
      expect 0 <= position < backing.size
      expect-equals 0 position % step
      key := backing[position]
      if key is not Tombstone_:
        expect-equals (key.hash-code & 0xfff) (slot & 0xfff)

/// A key that is only equal to itself (`==` is true for identical objects
///   without calling the operator), with a constant hash code.
class Unequal:
  hash-code -> int: return 42
  operator == other -> bool: return false

/// Every addition of an $Unequal key appends a new entry, also when the
///   index is rebuilt while the key is added.
test-unequal-keys:
  map := {:}
  60.repeat:
    map[Unequal] = it
    map[it] = it
    if it % 3 == 0: map.remove it
  expect-equals 100 map.size
  values := []
  map.do: | k v | if k is Unequal: values.add v
  expect-equals (List 60: it) values
  map.do: | k v | if k is int: expect-equals k map[k]

  // Fill the index while it has slots of deleted entries, so that adding a
  // key rebuilds it.
  [8, 20, 50].do: | n |
    map = {:}
    n.repeat: map[it] = it
    (n / 4).repeat: map.remove it
    (3 * n).repeat:
      map[Unequal] = it
      map[1000 + it] = it
      check-index map 2
    expect-equals (n - n / 4 + 6 * n) map.size
    values = []
    map.do: | k v |
      if k is Unequal: values.add v
      else: expect-equals v (k >= 1000 ? k - 1000 : k)
    expect-equals (List 3 * n: it) values
    map.do --keys: if it is int: expect (map.contains it)
    (3 * n).repeat: expect-equals it map[1000 + it]

    // The same for the lookup-or-add of sets that JSON decoding uses.
    set := {}
    n.repeat: set.add it
    (n / 4).repeat: set.remove it
    (3 * n).repeat:
      key := 1000 + it
      result := set.get-by-hash_ key.hash-code
          --initial=: key
          --compare=: it == key
      expect-equals key result
    expect-equals (n - n / 4 + 3 * n) set.size

class Key:
  id/int
  constructor .id:
  // Many collisions.
  hash-code -> int: return id % 7
  operator == other -> bool: return other is Key and other.id == id

ABSENT ::= Object

/**
A reference map from small integers to values: linear-time iteration, but
  simple.  Keys are integers in [0, $range).
*/
class RefMap:
  range/int
  values/List
  stamps/List
  order-keys/List := []
  order-stamps/List := []
  size := 0
  stamp := 0

  constructor .range:
    values = List range ABSENT
    stamps = List range -1

  contains k/int -> bool: return not identical ABSENT values[k]

  set k/int v -> none:
    if not contains k:
      size++
      stamp++
      stamps[k] = stamp
      order-keys.add k
      order-stamps.add stamp
    values[k] = v

  remove k/int -> none:
    if not contains k: return
    values[k] = ABSENT
    size--
    if order-keys.size > 2 * size + 64:
      new-keys := []
      new-stamps := []
      do: | key |
        new-keys.add key
        new-stamps.add stamps[key]
      order-keys = new-keys
      order-stamps = new-stamps

  clear -> none:
    values.fill ABSENT
    order-keys = []
    order-stamps = []
    size = 0

  do [block] -> none:
    order-keys.size.repeat:
      k := order-keys[it]
      if contains k and stamps[k] == order-stamps[it]: block.call k

  keys -> List:
    result := []
    do: result.add it
    return result

  /// A random present key: the oldest, the newest, or any.
  pick -> int:
    r := random 3
    if r == 0:
      do: return it
    else if r == 1:
      for i := order-keys.size - 1; i >= 0; i--:
        k := order-keys[i]
        if contains k and stamps[k] == order-stamps[i]: return k
    list := keys
    return list[random list.size]

/**
Runs random operations on a map and a set (with integer keys, or with keys
  that collide a lot) and compares them with the reference.  The size moves
  between targets that cover the sizes at which the index grows and shrinks.
*/
test-random:
  set-random-seed "map-churn-test"
  test-random --ops=150_000 --range=400 --colliding=false
  test-random --ops=60_000 --range=200 --colliding=true

test-random --ops/int --range/int --colliding/bool:
  TARGETS ::= [0, 1, 2, 3, 4, 5, 6, 7, 12, 13, 14, 26, 27, 28, 53, 54, 55, 107, 108, 109, 216, 217, 218, 300]
  key := : | k | colliding ? (Key k) : k
  map := {:}
  set := {}
  ref := RefMap range
  target := 0
  ops.repeat: | step |
    if step % 500 == 0: target = TARGETS[random TARGETS.size]
    r := random 100
    if r < 2:
      // Rare: filter in place, keeping about half.
      mod := 2 + (random 3)
      keep := : | k | k % mod != 0
      map.filter --in-place: | k v | keep.call (colliding ? k.id : k)
      set.filter --in-place: keep.call (colliding ? it.id : it)
      ref.keys.do: if not keep.call it: ref.remove it
    else if r < 3 and (random 20) == 0:
      map.clear
      set.clear
      ref.clear
    else if r < 15:
      // Lookup, present or absent.
      k := random range
      expect-equals (ref.contains k) (map.contains (key.call k))
      expect-equals (ref.contains k) (set.contains (key.call k))
      if ref.contains k: expect-equals ref.values[k] (map.get (key.call k))
      else: expect-null (map.get (key.call k))
    else if r < 25 and ref.size > 0:
      // Update an existing key; doesn't change the order.
      k := ref.pick
      map[key.call k] = step
      set.add (key.call k)
      ref.set k step
    else if ref.size < target or (ref.size == target and r < 60):
      k := random range
      map[key.call k] = step
      set.add (key.call k)
      ref.set k step
    else:
      k := (ref.size > 0 and r < 90) ? ref.pick : random range
      map.remove (key.call k)
      set.remove (key.call k)
      ref.remove k
      expect-not (map.contains (key.call k))
    expect-equals ref.size map.size
    expect-equals ref.size set.size
    if step % 101 == 0:
      check-index map 2
      check-index set 1
    if ref.size < 10 or step % 101 == 0:
      expected := ref.keys
      actual := []
      map.do: | k v |
        id := colliding ? k.id : k
        actual.add id
        expect-equals ref.values[id] v
      expect-equals expected actual
      actual = []
      set.do: actual.add (colliding ? it.id : it)
      expect-equals expected actual
      if expected.size > 0:
        last := null
        map.do --reversed: | k v | last = k
        expect-equals expected.first (colliding ? last.id : last)
