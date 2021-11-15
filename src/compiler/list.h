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
  ListBuilder() { }

  int length() const { return _data.size(); }
  bool is_empty() const { return _data.empty(); }

  void clear() {
    _data.clear();
  }

  void add(T element) {
    _data.push_back(element);
  }

  void add(List<T> elements) {
    if (elements.is_empty()) return;
    _data.reserve(_data.size() + elements.length());
    _data.insert(_data.end(), elements.begin(), elements.end());
  }

  T& last() {
    ASSERT(length() > 0);
    return _data.back();
  }

  T remove_last() {
    ASSERT(!is_empty());
    T result = _data.back();
    _data.pop_back();
    return result;
  }

  T& operator[](int index) {
    ASSERT(index >= 0 && index < length());
    return _data[index];
  }

  const T& operator[](int index) const {
    ASSERT(index >= 0 && index < length());
    return _data[index];
  }

  static List<T> allocate(int length) {
    T* data = _new T[length]();
    return List<T>(data, length);
  }

  List<T> build() {
    return build_from_vector(_data);
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

  static List<T> build_from_vector(std::vector<T> vector) {
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
  std::vector<T> _data;
};

} // namespace toit::compiler
} // namespace toit
