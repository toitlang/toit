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
    auto probe = map_.find(key);
    if (probe == map_.end()) {
      vector_.push_back(key);
      return map_[key];
    } else {
      return probe->second;
    }
  }

  void set(const K& key, const V& value) {
    auto probe = map_.find(key);
    if (probe == map_.end()) {
      vector_.push_back(key);
      map_.emplace(key, value);
    } else {
      probe->second = value;
    }
  }

  V at(const K& key) { return map_.at(key); }
  const V at(const K& key) const { return map_.at(key); }

  template<typename F>
  void for_each(const F& callback) {
    for (auto key : vector_) {
      callback(key, map_[key]);
    }
  }

  bool contains_key(const K& key) {
    return map_.find(key) != map_.end();
  }

  typename std::unordered_map<K, V>::iterator find(const K& key) {
    return map_.find(key);
  }
  typename std::unordered_map<K, V>::const_iterator find(const K& key) const {
    return map_.find(key);
  }
  typename std::unordered_map<K, V>::iterator end() { return map_.end(); }
  typename std::unordered_map<K, V>::const_iterator end() const { return map_.end(); }

  std::vector<K>& keys() { return vector_; }
  const std::vector<K>& keys() const { return vector_; }

  std::unordered_map<K, V>& underlying_map() { return map_; }
  const std::unordered_map<K, V>& underlying_map() const { return map_; }

  bool empty() const { return vector_.empty(); }
  int size() const { return vector_.size(); }

  void clear() {
    map_.clear();
    vector_.clear();
  }

 private:
  std::unordered_map<K, V> map_;
  std::vector<K> vector_;  // To keep insertion order.
};

template<typename K, typename V> class Map<K, V*> {
 public:
  V*& operator [](const K& key) {
    auto probe = map_.find(key);
    if (probe == map_.end()) {
      vector_.push_back(key);
      return map_[key];
    } else {
      return probe->second;
    }
  }

  V* at(const K& key) { return map_.at(key); }

  V* lookup(const K& key) {
    auto probe = map_.find(key);
    if (probe == map_.end()) return null;
    return probe->second;
  }

  typename std::unordered_map<K, V*>::iterator find(const K& key) {
    return map_.find(key);
  }
  typename std::unordered_map<K, V*>::const_iterator find(const K& key) const {
    return map_.find(key);
  }
  typename std::unordered_map<K, V*>::iterator end() { return map_.end(); }
  typename std::unordered_map<K, V*>::const_iterator end() const { return map_.end(); }

  std::vector<K>& keys() { return vector_; }

  std::unordered_map<K, V*>& underlying_map() { return map_; }

  bool empty() const { return vector_.empty(); }
  int size() const { return vector_.size(); }

  void clear() {
    map_.clear();
    vector_.clear();
  }

 private:
  std::unordered_map<K, V*> map_;
  std::vector<K> vector_;  // To keep insertion order.
};

/// A wrapper around the std::set to make its API more convenient and close to
/// how we use it.
template<typename K, typename V> class UnorderedMap {
 public:
  typename std::unordered_map<K, V>::iterator find(const K& key) { return map_.find(key); }
  typename std::unordered_map<K, V>::iterator end() { return map_.end(); }

  bool add(const K& key, V value) {
    auto pair = map_.insert({key, value});
    if (pair.second) {
      pair.first->second = value;
    }
    return pair.second;
  }

  void add_all(const UnorderedMap<K, V>& other) {
    map_.insert(other.map_.begin(), other.map_.end());
  }

  V& operator [](const K& key) { return map_[key]; }
  V at(const K& key) { return map_.at(key); }
  const V at(const K& key) const { return map_.at(key); }

  std::unordered_map<K, V>& underlying_map() { return map_; }

  bool empty() const { return map_.empty(); }
  int size() const { return map_.size(); }

  void clear() { map_.clear(); }

  bool remove(const K& key) { return map_.erase(key) > 0; }

 private:
  std::unordered_map<K, V> map_;
};

/// A wrapper around the std::set to make its API more convenient and close to
/// how we use it.
template<typename K, typename V> class UnorderedMap<K, V*> {
 public:
  typename std::unordered_map<K, V*>::iterator find(const K& key) { return map_.find(key); }
  typename std::unordered_map<K, V*>::iterator end() { return map_.end(); }

  bool add(const K& key, V* value) {
    auto pair = map_.insert({key, value});
    if (pair.second) {
      pair.first->second = value;
    }
    return pair.second;
  }

  void add_all(const UnorderedMap<K, V*>& other) {
    map_.insert(other.map_.begin(), other.map_.end());
  }

  V*& operator [](const K& key) { return map_[key]; }

  V* lookup(const K& key) const {
    auto probe = map_.find(key);
    if (probe == map_.end()) return null;
    return probe->second;
  }

  V* at(const K& key) const { return map_.at(key); }

  std::unordered_map<K, V*>& underlying_map() { return map_; }

  bool empty() const { return map_.empty(); }
  int size() const { return map_.size(); }

  void clear() { map_.clear(); }

  bool remove(const K& key) { return map_.erase(key) > 0; }

 private:
  std::unordered_map<K, V*> map_;
};


} // namespace toit::compiler
} // namespace toit
