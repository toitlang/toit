// Copyright (C) 2019 Toitware ApS.
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

namespace toit {

// This is a simple profile designed for an interpreter and minimal space usage.

class Profiler {
 public:
  Profiler(int task_id);
  ~Profiler();

  bool is_active() { return is_active_; }
  int allocated_bytes() { return _allocated_bytes; }

  void start();
  void stop();

  void print();

  void encode_on(ProgramOrientedEncoder* encoder, String* title, int cutoff);

  // Every method that has bytecodes must be registered before executing any of
  // its bytecodes.
  void register_method(int absolute_bci);

  // One more bytecode has been executed in the current method.
  void increment(int absolute_bci);

  // Tells if a task should profile.
  bool should_profile_task(int task_id) {
    return is_active_ && (task_id_ == -1 || task_id == task_id_);
  }

 private:
  int task_id_;
  int table_size;
  int last_index = 0;
  // We grow the offset and counter tables whenever we see a new function.
  int* offset_table = null;
  int64* counter_table = null;
  bool is_active_ = false;
  int _allocated_bytes = 0;

  // Computes the highest index in the offset_table that is lower than
  //   the given [absolute_bci].
  int compute_index_for_absolute_bci(int absolute_bci);
};

} // namespace toit
