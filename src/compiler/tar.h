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

#include <functional>
#include <stdio.h>

#include "../top.h"

namespace toit {
namespace compiler {

/// The possible exit-codes for untar.
enum class UntarCode {
  ok,
  not_found,
  not_ustar,
  other
};

/// If `path` is equal to `-` uses `stdin`.
UntarCode untar(const char* path,
                const std::function<void (const char* name,
                                          char* source,
                                          int size)>& callback);

UntarCode untar(FILE* file,
                const std::function<void (const char* name,
                                          char* source,
                                          int size)>& callback);

bool is_tar_file(const char* path);

} // namespace toit::compiler
} // namespace toit
