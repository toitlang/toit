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
    elements_ = static_cast<Element*>(malloc(sizeof(Element) * size_));
    if (!elements_) FATAL("cannot allocate resource pool");
    fill(elements_, 0, rest...);
  }

  ~ResourcePool() {
    free(elements_);
  }

  // Get any resource from the pool. Returns Invalid if none is available.
  T any() {
    Locker locker(OS::global_mutex());
    return any(locker);
  }

  // Take a given resource from the pool. Returns false if it's not available.
  bool take(T value) {
    Locker locker(OS::global_mutex());
    return take(locker, value);
  }

  // Take a given resource from the pool if available, otherwise take any.
  T preferred(T value) {
    Locker locker(OS::global_mutex());
    return take(locker, value) ? value : any(locker);
  }

  // Put a resource back in the pool.
  void put(T value) {
    Locker locker(OS::global_mutex());
    for (int i = 0; i < size_; i++) {
      Element* element = &elements_[i];
      if (element->value == value) {
        ASSERT(element->taken);
        element->taken = false;
        return;
      }
    }
    FATAL("cannot add unknown resource");
  }

 private:
  struct Element {
    T value;
    bool taken;
  };

  static int count() {
    return 0;
  }

  template<typename... Ts>
  static int count(T value, Ts... rest) {
    return 1 + count(rest...);
  }

  static void fill(Element* elements, int index) {
    return;
  }

  template<typename... Ts>
  static void fill(Element* elements, int index, T value, Ts... rest) {
    elements[index] = { .value = value, .taken = false };
    fill(elements, index + 1, rest...);
  }

  bool take(Locker& locker, T value) {
    for (int i = 0; i < size_; i++) {
      Element* element = &elements_[i];
      if (element->value == value) {
        if (element->taken) return false;
        element->taken = true;
        return true;
      }
    }
    return false;
  }

  T any(Locker& locker) {
    for (int i = 0; i < size_; i++) {
      Element* element = &elements_[i];
      if (!element->taken) {
        element->taken = true;
        return element->value;
      }
    }
    return Invalid;
  }

  const int size_;
  Element* elements_;
};

} // namespace toit
