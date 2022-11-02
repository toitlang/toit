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

#include "ir.h"
#include "list.h"
#include "map.h"

namespace toit {
namespace compiler {

namespace ir {
  class Class;
  class Method;
  class Global;
} // namespace toit::compiler::ir

typedef Selector<PlainShape> DispatchSelector;

class DispatchTable {
 public:
  static DispatchTable build(List<ir::Class*> classes,
                             List<ir::Method*> methods);

  int length() const { return table_.length(); }

  // Returns the slot-index for *static* methods.
  //
  // Instance methods might exist multiple times in the dispatch table and thus
  // must use `for_each_slot_index`.
  int slot_index_for(const ir::Method* method) const;

  // Executes the given `callback` for every slot that contains the given
  // `member` (method or field) for the given `dispatch_offset`.
  // Note that the dispatch_offset is different for getters and setters.
  void for_each_slot_index(const ir::Method* member,
                           int dispatch_offset,
                           std::function<void (int)>& callback) const;

  // The dispatch offset defines all methods of a given selector.
  //
  // It is used to rapidly find target methods for virtual calls. The
  // combination of `holder + selector` points to a slot. There we can then
  // check whether the slot-entry has the right selector, and if yes, invoke it.
  int dispatch_offset_for(const DispatchSelector& selector) {
    auto probe = selector_offsets_.find(selector);
    if (probe != selector_offsets_.end()) return probe->second;
    return -1;
  }
  int id_for(const ir::Class* klass) const { return klass->start_id(); }

  void for_each_selector_offset(std::function<void (DispatchSelector, int)> callback) {
    selector_offsets_.for_each(callback);
  }

 private:
  DispatchTable(List<ir::Method*> table,
                const Map<DispatchSelector, int>& selector_offsets)
      : table_(table), selector_offsets_(selector_offsets) { }

  List<ir::Method*> table_;
  Map<DispatchSelector, int> selector_offsets_;
};

} // namespace toit::compiler
} // namespace toit
