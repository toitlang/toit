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

namespace toit {

// All functions that can be called directly from the interpreter.
#define ENTRY_POINTS(E) \
  E(entry_main,               __entry__main, 0)                   \
  E(entry_spawn,              __entry__spawn, 0)                  \
  E(entry_task,               __entry__task, 1)                   \
  E(lookup_failure,           lookup_failure_, 2)                 \
  E(as_check_failure,         as_check_failure_, 2)               \
  E(primitive_lookup_failure, primitive_lookup_failure_, 2)       \
  E(allocation_failure,       allocation_failure_, 1)             \
  E(code_failure,             too_few_code_arguments_failure_, 4) \
  E(program_failure,          program_failure_, 1)                \
  E(run_global_initializer,   run_global_initializer_, 2)         \

} // namespace toit
