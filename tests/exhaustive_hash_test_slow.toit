// Copyright (C) 2019 Toitware ApS. All rights reserved.

main:
  random_test true
  random_test false
  random_set_test true
  random_set_test false

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

  contains_all collection/Collection -> bool:
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

  is_empty:
    return size == 0

  remove key -> none:
    remove key --if_absent=: return

  remove key [--if_absent]:
    keys_.size.repeat:
      if keys_[it] == key:
        result := values_[it]
        new_keys := keys_.copy 0 it
        new_values := values_.copy 0 it
        new_keys.add_all (keys_.copy it + 1)
        new_values.add_all (values_.copy it + 1)
        keys_ = new_keys
        values_ = new_values
        return result
    return if_absent.call key

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

  is_empty:
    return map_.is_empty

random_test with_deletion:
  MAPS_COUNT ::= 10
  KEYS ::= 30
  ITERATIONS ::= 2000
  maps := List
  control_maps := List
  MAPS_COUNT.repeat:
    maps.add Map
    control_maps.add ControlMap
  ITERATIONS.repeat:
    source := random MAPS_COUNT
    dest := source
    while dest == source:
      dest = random MAPS_COUNT
    key := "$(random KEYS)"
    value := (random 1) == 0 ? key : "value$key"
    control_maps[dest] = ControlMap
    control_maps[source].do: | key value | control_maps[dest][key] = value
    maps[dest] = Map
    maps[source].do: | key value | maps[dest][key] = value
    if with_deletion:
      if (random 2) < 1:
        // Add entry.
        maps[dest][key] = value
        control_maps[dest][key] = value
      else:
        maps[dest].remove key
        control_maps[dest].remove key
    else:
      if (random 30) == 0:
        maps[dest] = Map
        control_maps[dest] = ControlMap
      else:
        // Add entry.
        maps[dest][key] = value
        control_maps[dest][key] = value
    MAPS_COUNT.repeat: | i |
      assert: maps[i].size == control_maps[i].size
      KEYS.repeat: | k |
        key2 := "$k"
        if control_maps[i].contains key2:
          assert: maps[i].contains key2
          assert: maps[i][key2] == control_maps[i][key2]
        else:
          assert: not maps[i].contains key2
          assert: null == (control_maps[i].get key2)

random_set_test with_deletion:
  SETS_COUNT ::= 10
  KEYS ::= 30
  ITERATIONS ::= 200
  sets := List
  control_sets := List
  SETS_COUNT.repeat:
    sets.add Set
    control_sets.add ControlSet
  ITERATIONS.repeat:
    source := random SETS_COUNT
    dest := source
    while dest == source:
      dest = random SETS_COUNT
    key := "$(random KEYS)"
    control_sets[dest] = ControlSet
    control_sets[source].do: | key | control_sets[dest].add key
    sets[dest] = Set
    sets[source].do: | key | sets[dest].add key
    if with_deletion:
      if (random 3) < 2:
        // Add entry.
        sets[dest].add key
        control_sets[dest].add key
      else:
        sets[dest].remove key
        control_sets[dest].remove key
    else:
      if (random 30) == 0:
        sets[dest] = Set
        control_sets[dest] = ControlSet
      else:
        // Add entry.
        sets[dest].add key
        control_sets[dest].add key
    SETS_COUNT.repeat: | i |
      assert: sets[i].size == control_sets[i].size
      KEYS.repeat: | k |
        key2 := "$k"
        if control_sets[i].contains key2:
          assert: sets[i].contains key2
        else:
          assert: not sets[i].contains key2
