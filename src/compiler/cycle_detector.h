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
    return static_cast<int>(in_progress_.size());
  }

  void start(const T& entry) {
    ASSERT(in_progress_map_.find(entry) == in_progress_map_.end());
    in_progress_map_[entry] = in_progress_.size();
    in_progress_.push_back(entry);
  }

  void stop(const T& entry) {
    ASSERT(in_progress_.back() == entry);
    in_progress_map_.remove(entry);
    in_progress_.pop_back();
  }

  /// Checks whether the given entry is in a cycle.
  /// Returns false if the entry is not in a cycle.
  /// Otherwise:
  ///  * Creates a vector with all nodes of the cycle. If any of them have not been
  ///    in a cycle yet, calls the cycle_callback with the vector. Otherwise just returns true.
  ///  * Returns true.
  bool check_cycle(const T& entry,
                   const std::function<void (const std::vector<T>& cycle)> cycle_callback) {
    auto probe = in_progress_map_.find(entry);
    if (probe == in_progress_map_.end()) return false;
    // We are in a cycle.
    auto cycle = std::vector<T>(in_progress_.begin() + probe->second, in_progress_.end());
    cycle_callback(cycle);
    return true;
  }

 private:
  UnorderedMap<T, int> in_progress_map_;
  std::vector<T> in_progress_;
};

} // namespace toit::compiler
} // namespace toit
