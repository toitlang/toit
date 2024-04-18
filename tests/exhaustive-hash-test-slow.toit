// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  random-test true
  random-test false
  random-set-test true
  random-set-test false

// A really stupid map implementation for comparing with the fast one.
class ControlMap:
  keys_ := List
  values_ := List

  operator [] key:
    keys_.size.repeat:
      if keys_[it] == key: return values_[it]
    throw "key not found"

  get key:
    keys_.size.repeat:
      if keys_[it] == key: return values_[it]
    return null

  do [block]:
    keys_.size.repeat:
      block.call keys_[it] values_[it]

  do --keys [block]:
    keys_.size.repeat:
      block.call keys_[it]

  do --values [block]:
    keys_.size.repeat:
      block.call values_[it]

  contains key:
    keys_.size.repeat:
      if keys_[it] == key: return true
    return false

  contains-all collection/Collection -> bool:
    collection.do: if not contains it: return false
    return true

  operator []= key value:
    keys_.size.repeat:
      if keys_[it] == key:
        values_[it] = value
        return value
    keys_.add key
    values_.add value
    return value

  size:
    return keys_.size

  is-empty:
    return size == 0

  remove key -> none:
    remove key --if-absent=: return

  remove key [--if-absent]:
    keys_.size.repeat:
      if keys_[it] == key:
        result := values_[it]
        new-keys := keys_.copy 0 it
        new-values := values_.copy 0 it
        new-keys.add-all (keys_.copy it + 1)
        new-values.add-all (values_.copy it + 1)
        keys_ = new-keys
        values_ = new-values
        return result
    return if-absent.call key

  clear:
    keys_ = List
    values_ = List

class ControlSet:
  map_ := Map

  contains key:
    return map_.contains key

  add key:
    return map_[key] = 1

  do [block]:
    map_.do --keys: block.call it

  clear:
    return map_.clear

  size:
    return map_.size

  remove key:
    return map_.remove key

  is-empty:
    return map_.is-empty

random-test with-deletion:
  MAPS-COUNT ::= 10
  KEYS ::= 30
  ITERATIONS ::= 2000
  maps := List
  control-maps := List
  MAPS-COUNT.repeat:
    maps.add Map
    control-maps.add ControlMap
  ITERATIONS.repeat:
    source := random MAPS-COUNT
    dest := source
    while dest == source:
      dest = random MAPS-COUNT
    key := "$(random KEYS)"
    value := (random 1) == 0 ? key : "value$key"
    control-maps[dest] = ControlMap
    control-maps[source].do: | key value | control-maps[dest][key] = value
    maps[dest] = Map
    maps[source].do: | key value | maps[dest][key] = value
    if with-deletion:
      if (random 2) < 1:
        // Add entry.
        maps[dest][key] = value
        control-maps[dest][key] = value
      else:
        maps[dest].remove key
        control-maps[dest].remove key
    else:
      if (random 30) == 0:
        maps[dest] = Map
        control-maps[dest] = ControlMap
      else:
        // Add entry.
        maps[dest][key] = value
        control-maps[dest][key] = value
    MAPS-COUNT.repeat: | i |
      assert: maps[i].size == control-maps[i].size
      KEYS.repeat: | k |
        key2 := "$k"
        if control-maps[i].contains key2:
          assert: maps[i].contains key2
          assert: maps[i][key2] == control-maps[i][key2]
        else:
          assert: not maps[i].contains key2
          assert: null == (control-maps[i].get key2)

random-set-test with-deletion:
  SETS-COUNT ::= 10
  KEYS ::= 30
  ITERATIONS ::= 200
  sets := List
  control-sets := List
  SETS-COUNT.repeat:
    sets.add Set
    control-sets.add ControlSet
  ITERATIONS.repeat:
    source := random SETS-COUNT
    dest := source
    while dest == source:
      dest = random SETS-COUNT
    key := "$(random KEYS)"
    control-sets[dest] = ControlSet
    control-sets[source].do: | key | control-sets[dest].add key
    sets[dest] = Set
    sets[source].do: | key | sets[dest].add key
    if with-deletion:
      if (random 3) < 2:
        // Add entry.
        sets[dest].add key
        control-sets[dest].add key
      else:
        sets[dest].remove key
        control-sets[dest].remove key
    else:
      if (random 30) == 0:
        sets[dest] = Set
        control-sets[dest] = ControlSet
      else:
        // Add entry.
        sets[dest].add key
        control-sets[dest].add key
    SETS-COUNT.repeat: | i |
      assert: sets[i].size == control-sets[i].size
      KEYS.repeat: | k |
        key2 := "$k"
        if control-sets[i].contains key2:
          assert: sets[i].contains key2
        else:
          assert: not sets[i].contains key2
