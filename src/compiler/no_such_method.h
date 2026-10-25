// Copyright (C) 2021 Toitware ApS.
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

#include "ast_resolution.h"
#include "../top.h"
#include "list.h"
#include "selector.h"
#include "sources.h"
#include "symbol.h"

namespace toit {
namespace compiler {

class ResolutionQueryableClass;
class Diagnostics;

namespace resolution {
  class NodeInfo; using NodeView = View<NodeInfo>;
  class ClassInfo; using ClassView = View<ClassInfo>;
}

void report_no_such_instance_method(resolution::ClassView klass,
                                    const Selector<CallShape>& selector,
                                    const Source::Range& range,
                                    Diagnostics* diagnostics);


void report_no_such_static_method(List<resolution::NodeView> candidates,
                                  const Selector<CallShape>& selector,
                                  const Source::Range& range,
                                  Diagnostics* diagnostics);

} // namespace toit::compiler
} // namespace toit
