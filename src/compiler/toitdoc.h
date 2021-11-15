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

#include <functional>

#include "ast.h"
#include "ir.h"
#include "list.h"
#include "map.h"
#include "scanner.h"
#include "symbol.h"
#include "sources.h"

namespace toit {
namespace compiler {

namespace toitdoc {
class Contents;
}

// Forward declaration.
class Module;

template<typename RefNode>
class Toitdoc {
 public:
  Toitdoc(toitdoc::Contents* contents,
          List<RefNode> refs,
          Source::Range range)
      : _contents(contents)
      , _refs(refs)
      , _range(range) { }

  Toitdoc()  // Needed, so it can be used as a map value.
      : _contents(null)
      , _range(Source::Range::invalid()) { }

  bool is_valid() const { return _contents != null; }
  toitdoc::Contents* contents() const { return _contents; }
  List<RefNode> refs() const { return _refs; }

  Source::Range range() const { return _range; }

  static Toitdoc invalid() {
    return Toitdoc();
  }

 private:
  toitdoc::Contents* _contents;
  List<RefNode> _refs;
  Source::Range _range;
};

class ToitdocRegistry {
 public:
  Toitdoc<ir::Node*> toitdoc_for(ir::Node* node) const { return toitdoc_for(static_cast<void*>(node)); }
  Toitdoc<ir::Node*> toitdoc_for(Module* module) const { return toitdoc_for(static_cast<void*>(module)); }

  void set_toitdoc(ir::Node* node, Toitdoc<ir::Node*> toitdoc) {
    _map[static_cast<void*>(node)] = toitdoc;
  }

  void set_toitdoc(Module* module, Toitdoc<ir::Node*> toitdoc) {
    _map[static_cast<void*>(module)] = toitdoc;
  }

  template<typename F>
  void for_each(const F& callback) {
    _map.for_each(callback);
  }

 private:
  Toitdoc<ir::Node*> toitdoc_for(void* node) const {
    auto probe = _map.find(node);
    if (probe == _map.end()) return Toitdoc<ir::Node*>::invalid();
    return probe->second;
  }

  Map<void*, Toitdoc<ir::Node*>> _map;
};

} // namespace toit::compiler
} // namespace toit
