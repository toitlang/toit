// Copyright (C) 2018 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

#include <unordered_map>
#include <vector>
#include "../top.h"

namespace toit {
namespace compiler {

template<typename K, typename V> class Map {
 public:
  V& operator [](const K& key) {
    auto probe = _map.find(key);
    if (probe == _map.end()) {
      _vector.push_back(key);
      return _map[key];
    } else {
      return probe->second;
    }
  }

  void set(const K& key, const V& value) {
    auto probe = _map.find(key);
    if (probe == _map.end()) {
      _vector.push_back(key);
      _map.emplace(key, value);
    } else {
      probe->second = value;
    }
  }

  V at(const K& key) { return _map.at(key); }
  const V at(const K& key) const { return _map.at(key); }

  template<typename F>
  void for_each(const F& callback) {
    for (auto key : _vector) {
      callback(key, _map[key]);
    }
  }

  bool contains_key(const K& key) {
    return _map.find(key) != _map.end();
  }

  typename std::unordered_map<K, V>::iterator find(const K& key) {
    return _map.find(key);
  }
  typename std::unordered_map<K, V>::const_iterator find(const K& key) const {
    return _map.find(key);
  }
  typename std::unordered_map<K, V>::iterator end() { return _map.end(); }
  typename std::unordered_map<K, V>::const_iterator end() const { return _map.end(); }

  std::vector<K>& keys() { return _vector; }
  const std::vector<K>& keys() const { return _vector; }

  std::unordered_map<K, V>& underlying_map() { return _map; }
  const std::unordered_map<K, V>& underlying_map() const { return _map; }

  bool empty() const { return _vector.empty(); }
  int size() const { return _vector.size(); }

  void clear() {
    _map.clear();
    _vector.clear();
  }

 private:
  std::unordered_map<K, V> _map;
  std::vector<K> _vector;  // To keep insertion order.
};

template<typename K, typename V> class Map<K, V*> {
 public:
  V*& operator [](const K& key) {
    auto probe = _map.find(key);
    if (probe == _map.end()) {
      _vector.push_back(key);
      return _map[key];
    } else {
      return probe->second;
    }
  }

  V* at(const K& key) { return _map.at(key); }

  V* lookup(const K& key) {
    auto probe = _map.find(key);
    if (probe == _map.end()) return null;
    return probe->second;
  }

  typename std::unordered_map<K, V*>::iterator find(const K& key) {
    return _map.find(key);
  }
  typename std::unordered_map<K, V*>::const_iterator find(const K& key) const {
    return _map.find(key);
  }
  typename std::unordered_map<K, V*>::iterator end() { return _map.end(); }
  typename std::unordered_map<K, V*>::const_iterator end() const { return _map.end(); }

  std::vector<K>& keys() { return _vector; }

  std::unordered_map<K, V*>& underlying_map() { return _map; }

  bool empty() const { return _vector.empty(); }
  int size() const { return _vector.size(); }

  void clear() {
    _map.clear();
    _vector.clear();
  }

 private:
  std::unordered_map<K, V*> _map;
  std::vector<K> _vector;  // To keep insertion order.
};

/// A wrapper around the std::set to make its API more convenient and close to
/// how we use it.
template<typename K, typename V> class UnorderedMap {
 public:
  typename std::unordered_map<K, V>::iterator find(const K& key) { return _map.find(key); }
  typename std::unordered_map<K, V>::iterator end() { return _map.end(); }

  bool add(const K& key, V value) {
    auto pair = _map.insert({key, value});
    if (pair.second) {
      pair.first->second = value;
    }
    return pair.second;
  }

  void add_all(const UnorderedMap<K, V>& other) {
    _map.insert(other._map.begin(), other._map.end());
  }

  V& operator [](const K& key) { return _map[key]; }
  V at(const K& key) { return _map.at(key); }
  const V at(const K& key) const { return _map.at(key); }

  std::unordered_map<K, V>& underlying_map() { return _map; }

  bool empty() const { return _map.empty(); }
  int size() const { return _map.size(); }

  void clear() { _map.clear(); }

  bool remove(const K& key) { return _map.erase(key) > 0; }

 private:
  std::unordered_map<K, V> _map;
};

/// A wrapper around the std::set to make its API more convenient and close to
/// how we use it.
template<typename K, typename V> class UnorderedMap<K, V*> {
 public:
  typename std::unordered_map<K, V*>::iterator find(const K& key) { return _map.find(key); }
  typename std::unordered_map<K, V*>::iterator end() { return _map.end(); }

  bool add(const K& key, V* value) {
    auto pair = _map.insert({key, value});
    if (pair.second) {
      pair.first->second = value;
    }
    return pair.second;
  }

  void add_all(const UnorderedMap<K, V*>& other) {
    _map.insert(other._map.begin(), other._map.end());
  }

  V*& operator [](const K& key) { return _map[key]; }

  V* lookup(const K& key) const {
    auto probe = _map.find(key);
    if (probe == _map.end()) return null;
    return probe->second;
  }

  V* at(const K& key) const { return _map.at(key); }

  std::unordered_map<K, V*>& underlying_map() { return _map; }

  bool empty() const { return _map.empty(); }
  int size() const { return _map.size(); }

  void clear() { _map.clear(); }

  bool remove(const K& key) { return _map.erase(key) > 0; }

 private:
  std::unordered_map<K, V*> _map;
};


} // namespace toit::compiler
} // namespace toit
