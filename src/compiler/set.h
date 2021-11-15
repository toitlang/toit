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

#include <unordered_set>
#include <vector>

#include "list.h"
#include "../top.h"

namespace toit {
namespace compiler {

template<typename T> class Set {
 public:
  void insert(T x) {
    auto p = _set.insert(x);
    if (p.second) _vector.push_back(x);
  }

  template<class InputIt> void insert(InputIt begin, InputIt end) {
    while (begin != end) {
      insert(*begin);
      begin++;
    }
  }

  void insert_all(Set<T> other_set) {
    for (auto& x : other_set) insert(x);
  }

  void erase_all(const Set<T>& other_set) {
    bool did_erase = false;
    for (auto& x : other_set._set) {
      size_t removed_count = _set.erase(x);
      did_erase |= removed_count != 0;
    }
    if (did_erase) {
      // Keep one element so we can pass it to `resize`.
      T dummy = _vector[0];
      size_t i = 0;
      int j = 0;
      for (; i < _vector.size(); i++) {
        if (!other_set.contains(_vector[i])) _vector[j++] = _vector[i];
      }
      // The dummy argument is unused since we only shrink here.
      _vector.resize(j, dummy);
    }
  }

  void erase_last(T x) {
    ASSERT(_vector.back() == x);
    _set.erase(x);
    _vector.pop_back();
  }

  typename std::vector<T>::iterator begin() { return _vector.begin(); }
  typename std::vector<T>::iterator end() { return _vector.end(); }
  typename std::vector<T>::const_iterator begin() const { return _vector.begin(); }
  typename std::vector<T>::const_iterator end() const { return _vector.end(); }

  bool contains(T x) const { return _set.find(x) != _set.end(); }
  bool empty() const { return _set.empty(); }
  void clear() { _set.clear(); _vector.clear(); }
  int size() const { return static_cast<int>(_set.size()); }

  List<T> to_list() const { return ListBuilder<T>::build_from_vector(_vector); }
  std::vector<T> to_vector() const { return _vector; }

 private:
  std::unordered_set<T> _set;
  std::vector<T> _vector;  // To keep insertion order.
};

/// A wrapper around the std::set to make its API more convenient and close to
/// how we use it.
template<typename T> class UnorderedSet {
 public:
  void insert(T x) { _set.insert(x); }
  template<class InputIt> void insert(InputIt begin, InputIt end) { _set.insert(begin, end); }
  void insert_all(UnorderedSet<T> other_set) {
    _set.insert(other_set._set.begin(), other_set._set.end());
  }
  void insert_all(Set<T> other_set) {
    _set.insert(other_set.begin(), other_set.end());
  }
  bool erase(T x) { return _set.erase(x) > 0; }

  template<typename E>
  void erase_all(const List<E>& other) {
    for (auto entry : other) {
      _set.erase(entry);
    }
  }

  bool contains(T x) const { return _set.find(x) != _set.end(); }
  bool empty() const { return _set.empty(); }
  void clear() { _set.clear(); }
  int size() const { return static_cast<int>(_set.size()); }

  const std::unordered_set<T>& underlying_set() const { return _set; }
  std::unordered_set<T>& underlying_set() { return _set; }

 private:
  std::unordered_set<T> _set;
};

} // namespace toit::compiler
} // namespace toit
