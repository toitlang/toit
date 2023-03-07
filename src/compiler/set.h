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
  bool insert(T x) {
    auto p = set_.insert(x);
    if (!p.second) return false;
    vector_.push_back(x);
    return true;
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
    for (auto& x : other_set.set_) {
      size_t removed_count = set_.erase(x);
      did_erase |= removed_count != 0;
    }
    if (did_erase) {
      // Keep one element so we can pass it to `resize`.
      T dummy = vector_[0];
      size_t i = 0;
      int j = 0;
      for (; i < vector_.size(); i++) {
        if (!other_set.contains(vector_[i])) vector_[j++] = vector_[i];
      }
      // The dummy argument is unused since we only shrink here.
      vector_.resize(j, dummy);
    }
  }

  void erase_last(T x) {
    ASSERT(vector_.back() == x);
    set_.erase(x);
    vector_.pop_back();
  }

  typename std::vector<T>::iterator begin() { return vector_.begin(); }
  typename std::vector<T>::iterator end() { return vector_.end(); }
  typename std::vector<T>::const_iterator begin() const { return vector_.begin(); }
  typename std::vector<T>::const_iterator end() const { return vector_.end(); }

  bool contains(T x) const { return set_.find(x) != set_.end(); }
  bool empty() const { return set_.empty(); }
  void clear() { set_.clear(); vector_.clear(); }
  int size() const { return static_cast<int>(set_.size()); }

  List<T> to_list() const { return ListBuilder<T>::build_from_vector(vector_); }
  std::vector<T> to_vector() const { return vector_; }

 private:
  std::unordered_set<T> set_;
  std::vector<T> vector_;  // To keep insertion order.
};

/// A wrapper around the std::set to make its API more convenient and close to
/// how we use it.
template<typename T> class UnorderedSet {
 public:
  void insert(T x) { set_.insert(x); }
  template<class InputIt> void insert(InputIt begin, InputIt end) { set_.insert(begin, end); }
  void insert_all(UnorderedSet<T> other_set) {
    set_.insert(other_set.set_.begin(), other_set.set_.end());
  }
  void insert_all(Set<T> other_set) {
    set_.insert(other_set.begin(), other_set.end());
  }
  bool erase(T x) { return set_.erase(x) > 0; }

  template<typename E>
  void erase_all(const List<E>& other) {
    for (auto entry : other) {
      set_.erase(entry);
    }
  }

  bool contains(T x) const { return set_.find(x) != set_.end(); }
  bool empty() const { return set_.empty(); }
  void clear() { set_.clear(); }
  int size() const { return static_cast<int>(set_.size()); }

  const std::unordered_set<T>& underlying_set() const { return set_; }
  std::unordered_set<T>& underlying_set() { return set_; }

 private:
  std::unordered_set<T> set_;
};

} // namespace toit::compiler
} // namespace toit
