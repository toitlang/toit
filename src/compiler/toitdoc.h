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

#include "ast_resolution.h"
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
  using ResolvedToitdoc = Toitdoc<resolution::View<resolution::Node>>;

  ResolvedToitdoc toitdoc_for(resolution::View<resolution::Node> node) const {
    return lookup(nodes_, node.node());
  }
  ResolvedToitdoc toitdoc_for(Module* module) const { return lookup(modules_, module); }

  void set_toitdoc(resolution::View<resolution::Node> node, ResolvedToitdoc toitdoc) {
    nodes_[node.node()] = toitdoc;
  }
  void set_toitdoc(Module* module, ResolvedToitdoc toitdoc) { modules_[module] = toitdoc; }

  template<typename F>
  void for_each(const F& callback) {
    nodes_.for_each([&](resolution::AstNode*, ResolvedToitdoc toitdoc) { callback(toitdoc); });
    modules_.for_each([&](Module*, ResolvedToitdoc toitdoc) { callback(toitdoc); });
  }

  template<typename F>
  void for_each_node(const F& callback) {
    nodes_.for_each([&](resolution::AstNode* node, ResolvedToitdoc toitdoc) {
      callback(resolution::View<resolution::Node>(node), toitdoc);
    });
  }

 private:
  template<typename Key>
  static ResolvedToitdoc lookup(const Map<Key, ResolvedToitdoc>& map, Key key) {
    auto probe = map.find(key);
    if (probe == map.end()) return ResolvedToitdoc::invalid();
    return probe->second;
  }

  Map<resolution::AstNode*, ResolvedToitdoc> nodes_;
  Map<Module*, ResolvedToitdoc> modules_;
};

} // namespace toit::compiler
} // namespace toit
