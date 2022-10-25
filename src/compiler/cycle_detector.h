// Copyright (C) 2022 Toitware ApS.
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

#include <functional>
#include <vector>
#include "../top.h"
#include "map.h"
#include "set.h"

namespace toit {
namespace compiler {

template<typename T>
class CycleDetector {
 public:
  int in_progress_size() const {
    return static_cast<int>(_in_progress.size());
  }

  void start(const T& entry) {
    ASSERT(_in_progress_map.find(entry) == _in_progress_map.end());
    _in_progress_map[entry] = _in_progress.size();
    _in_progress.push_back(entry);
  }

  void stop(const T& entry) {
    ASSERT(_in_progress.back() == entry);
    _in_progress_map.remove(entry);
    _in_progress.pop_back();
  }

  /// Checks whether the given entry is in a cycle.
  /// Returns false if the entry is not in a cycle.
  /// Otherwise:
  ///  * Creates a vector with all nodes of the cycle. If any of them have not been
  ///    in a cycle yet, calls the cycle_callback with the vector. Otherwise just returns true.
  ///  * Returns true.
  bool check_cycle(const T& entry,
                   const std::function<void (const std::vector<T>& cycle)> cycle_callback) {
    auto probe = _in_progress_map.find(entry);
    if (probe == _in_progress_map.end()) return false;
    // We are in a cycle.
    auto cycle = std::vector<T>(_in_progress.begin() + probe->second, _in_progress.end());
    cycle_callback(cycle);
    return true;
  }

 private:
  UnorderedMap<T, int> _in_progress_map;
  std::vector<T> _in_progress;
};

} // namespace toit::compiler
} // namespace toit
