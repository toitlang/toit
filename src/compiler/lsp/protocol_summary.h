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

#include <vector>

namespace toit {
namespace compiler {

class Module;
class ToitdocRegistry;
struct LspWriter;

void emit_summary(const std::vector<Module*>& modules,
                  int core_index,
                  const ToitdocRegistry& toitdocs,
                  LspWriter* writer);

} // namespace toit::compiler
} // namespace toit
