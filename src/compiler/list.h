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

#include "../top.h"

#include <vector>

#include "../utils.h"

namespace toit {
namespace compiler {

template<typename T>
class ListBuilder {
 public:
  ListBuilder() {}

  int length() const { return data_.size(); }
  bool is_empty() const { return data_.empty(); }

  void clear() {
    data_.clear();
  }

  void add(T element) {
    data_.push_back(element);
  }

  void add(List<T> elements) {
    if (elements.is_empty()) return;
    data_.reserve(data_.size() + elements.length());
    data_.insert(data_.end(), elements.begin(), elements.end());
  }

  T& last() {
    ASSERT(length() > 0);
    return data_.back();
  }

  T remove_last() {
    ASSERT(!is_empty());
    T result = data_.back();
    data_.pop_back();
    return result;
  }

  T& operator[](int index) {
    ASSERT(index >= 0 && index < length());
    return data_[index];
  }

  const T& operator[](int index) const {
    ASSERT(index >= 0 && index < length());
    return data_[index];
  }

  static List<T> allocate(int length) {
    T* data = _new T[length]();
    return List<T>(data, length);
  }

  List<T> build() {
    return build_from_vector(data_);
  }

  static List<T> build(T element) {
    int len = 1;
    List<T> result = allocate(len);
    *result.data() = element;
    return result;
  }

  static List<T> build(T element1, T element2) {
    int len = 2;
    List<T> result = allocate(len);
    result[0] = element1;
    result[1] = element2;
    return result;
  }

  static List<T> build(T element1, T element2, T element3) {
    int len = 3;
    List<T> result = allocate(len);
    result[0] = element1;
    result[1] = element2;
    result[2] = element3;
    return result;
  }

  static List<T> build_from_vector(const std::vector<T> vector) {
    int len = vector.size();
    List<T> result = allocate(len);
    for (int i = 0; i < len; i++) {
      result[i] = vector[i];
    }
    return result;
  }

  static List<T> build_from_array(T* data, int len) {
    List<T> result = allocate(len);
    for (int i = 0; i < len; i++) {
      result[i] = data[i];
    }
    return result;
  }

 private:
  std::vector<T> data_;
};

} // namespace toit::compiler
} // namespace toit
