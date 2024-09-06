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

#include "top.h"
#include "os.h"

namespace toit {

// Resource pool of a static set of resources. When manipulated, the global
// system lock will be taken.
template<typename T, T Invalid>
class ResourcePool {
 public:
  template<typename... Ts>
  ResourcePool(Ts... rest) : size_(count(rest...)) {
    values_ = static_cast<Value*>(malloc(sizeof(Value) * size_));
    if (!values_) FATAL("cannot allocate resource pool");
    fill(values_, 0, rest...);
  }

  ~ResourcePool() {
    free(values_);
  }

  // Get any resource from the pool. Returns Invalid if none is available.
  T any() {
    Locker locker(OS::global_mutex());
    return any(locker);
  }

  // Take a given resource from the pool. Returns false if it's not available.
  bool take(T t) {
    Locker locker(OS::global_mutex());
    return take(locker, t);
  }

  // Take a given resource from the pool if available, otherwise take any.
  T preferred(T t) {
    Locker locker(OS::global_mutex());

    if (take(locker, t)) {
      return t;
    }

    return any(locker);
  }

  // Put a resource back in the pool.
  void put(T t) {
    Locker locker(OS::global_mutex());
    for (int i = 0; i < size_; i++) {
      Value* value = &values_[i];
      if (value->t == t) {
        ASSERT(value->used);
        value->used = false;
        return;
      }
    }
    FATAL("cannot add unknown resource");
  }

 private:
  struct Value {
    T t;
    bool used;
  };

  static int count() {
    return 0;
  }

  template<typename... Ts>
  static int count(T value, Ts... rest) {
    return 1 + count(rest...);
  }

  static void fill(Value* values, int index) {
    return;
  }

  template<typename... Ts>
  static void fill(Value* values, int index, T value, Ts... rest) {
    values[index] = { value, false };
    fill(values, index + 1, rest...);
  }

  bool take(Locker& locker, T t) {
    for (int i = 0; i < size_; i++) {
      Value* value = &values_[i];
      if (value->t == t) {
        if (value->used) return false;
        value->used = true;
        return true;
      }
    }
    return false;
  }

  T any(Locker& locker) {
    for (int i = 0; i < size_; i++) {
      Value* value = &values_[i];
      if (!value->used) {
        value->used = true;
        return value->t;
      }
    }
    return Invalid;
  }

  const int size_;
  Value* values_;
};

} // namespace toit
