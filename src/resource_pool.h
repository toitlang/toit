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

// Resource pool of a static amount of resources. When used, the global system
// VM lock will be taken.
template<typename T, T Invalid>
class ResourcePool {
 public:
  ResourcePool() : _values(null) {}

  // TODO: Single allocation?
  template<typename... Ts>
  ResourcePool(T value, Ts... rest)
      : ResourcePool(rest...) {
    _values = _new Value({value, _values});
  }

  // Get any resource from the pool. Returns Invalid if none is available.
  T any() {
    Locker locker(OS::resource_mutex());
    return any(locker);
  }

  // Take a given resource from the pool. Returns false if it's not available.
  bool take(T t) {
    Locker locker(OS::resource_mutex());
    return take(locker, t);
  }

  // Take a given resource from the pool if available, otherwise take any.
  T preferred(T t) {
    Locker locker(OS::resource_mutex());

    if (take(locker, t)) {
      return t;
    }

    return any(locker);
  }

  // Put a resource back in the pool.
  void put(T value) {
    Locker locker(OS::resource_mutex());
    _values = _new Value({value, _values});
  }

 private:
  struct Value {
    T t;
    Value* next;
  };

  bool take(Locker& locker, T t) {
    Value* p = null;
    for (Value* c = _values; c != null; c = c->next) {
      if (c->t == t) {
        if (p != null) {
          p->next = c->next;
        } else {
          _values = c->next;
        }
        delete c;
        return true;
      }
      p = c;
    }

    return false;
  }

  T any(Locker& locker) {
    Value* value = _values;
    if (value == null) {
      return Invalid;
    }

    T t = value->t;
    _values = value->next;

    delete value;

    return t;
  }

  Value* _values;
};

} // namespace toit
