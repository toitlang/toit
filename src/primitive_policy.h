// Copyright (C) 2026 Toit contributors.
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
#include "primitive.h"

namespace toit {

// An immutable policy that decides which primitives a process group may
// call.
//
// Every process group has a policy. The processes of the group cache the
// pointer to it. The policies are statically allocated and shared.
class PrimitivePolicy {
 public:
  // Keep in sync with the POLICY- constants of ContainerService in
  // lib/system/api/containers.toit.
  enum Kind {
    SYSTEM = 0,     // The boot process. All primitives, PRIVILEGED ones included.
    TRUSTED = 1,    // Regular containers. All primitives except PRIVILEGED ones.
    UNTRUSTED = 2,  // Sandboxed containers. Only the allowed set.
  };

  // Must be called after Primitive::set_up.
  static void set_up();

  static const PrimitivePolicy* system() { return &system_; }
  static const PrimitivePolicy* trusted() { return &trusted_; }

  // Returns the standard policy for the given kind, or null if the kind is
  // not a launchable kind (the system policy can not be requested).
  static const PrimitivePolicy* launchable(int kind);

  Kind kind() const { return kind_; }
  bool is_system() const { return kind_ == SYSTEM; }
  bool is_untrusted() const { return kind_ == UNTRUSTED; }

  // Primitive lookup with bounds checks. Returns null if the module or index
  // is out of range or if the module is not linked or denied as a whole.
  // Denied entries in partially allowed modules have the arity of the real
  // primitive and a function that fails with PERMISSION_DENIED.
  const PrimitiveEntry* at(unsigned module, unsigned index) const {
    if (module >= Primitive::MODULE_COUNT) return null;
    if (index >= lengths_[module]) return null;
    return &tables_[module][index];
  }

 private:
  PrimitivePolicy() {}

  Kind kind_ = TRUSTED;
  const PrimitiveEntry* tables_[Primitive::MODULE_COUNT] = {};
  unsigned lengths_[Primitive::MODULE_COUNT] = {};

  void initialize_all(Kind kind);
  void initialize_untrusted();

  static PrimitivePolicy system_;
  static PrimitivePolicy trusted_;
  static PrimitivePolicy untrusted_;
};

} // namespace toit
