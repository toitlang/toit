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
#include "resolution.h"
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
      : contents_(contents)
      , refs_(refs)
      , range_(range) {}

  Toitdoc()  // Needed, so it can be used as a map value.
      : contents_(null)
      , range_(Source::Range::invalid()) {}

  bool is_valid() const { return contents_ != null; }
  toitdoc::Contents* contents() const { return contents_; }
  List<RefNode> refs() const { return refs_; }

  Source::Range range() const { return range_; }

  static Toitdoc invalid() {
    return Toitdoc();
  }

 private:
  toitdoc::Contents* contents_;
  List<RefNode> refs_;
  Source::Range range_;
};

class ToitdocRegistry {
 public:
  Toitdoc<resolution::Node*> toitdoc_for(resolution::Node* node) const { return toitdoc_for(static_cast<void*>(node)); }
  Toitdoc<resolution::Node*> toitdoc_for(Module* module) const { return toitdoc_for(static_cast<void*>(module)); }

  void set_toitdoc(resolution::Node* node, Toitdoc<resolution::Node*> toitdoc) {
    map_[static_cast<void*>(node)] = toitdoc;
  }

  void set_toitdoc(Module* module, Toitdoc<resolution::Node*> toitdoc) {
    map_[static_cast<void*>(module)] = toitdoc;
  }

  template<typename F>
  void for_each(const F& callback) {
    map_.for_each(callback);
  }

 private:
  Toitdoc<resolution::Node*> toitdoc_for(void* node) const {
    auto probe = map_.find(node);
    if (probe == map_.end()) return Toitdoc<resolution::Node*>::invalid();
    return probe->second;
  }

  Map<void*, Toitdoc<resolution::Node*>> map_;
};

} // namespace toit::compiler
} // namespace toit
