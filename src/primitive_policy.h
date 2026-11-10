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

class Process;

// Exit values used when the VM terminates a sandboxed process because it
// violated its policy. Keep in sync with lib/system/containers.toit.
static const int SANDBOX_EXIT_CPU_BUDGET = 241;
static const int SANDBOX_EXIT_DEVICE_HALT = 242;

// The quotas of a policy. A value of 0 means "unlimited".
struct PolicyQuotas {
  // The mailbox of a process with this policy holds at most
  // RECEIVER_FACTOR times the mailbox quotas in total.
  static const int RECEIVER_FACTOR = 4;

  word max_heap_bytes;        // Installed on every process in the group.
  word max_mailbox_messages;  // Messages a sender with this policy may have queued in one mailbox.
  word max_mailbox_bytes;     // Encoded bytes a sender with this policy may have queued in one mailbox.
  word max_message_bytes;     // Encoded size of a single outgoing message.
  word max_timers;            // Live timers per process.
  word max_processes;         // Live processes per group.
  int64 max_run_time_us;      // Uninterrupted run time before the process is killed.
  int64 cpu_budget_us;        // Total CPU time before the process is killed.
  word max_send_grants;       // Size of the allowed-target set of the group.
};

// An immutable policy that decides which primitives a process group may
// call, which quotas apply to it, and whether its messaging is restricted.
//
// Every process group has a policy. The processes of the group cache the
// pointer to it. The three standard policies are statically allocated and
// shared. Derived policies (a standard policy with different quotas) are
// owned by the process group they were created for.
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

  // Creates a policy for a launch request. The [description] is either
  // a Smi (the kind) or an Array of the form
  //   [kind, max_heap_bytes, max_mailbox_messages, max_mailbox_bytes,
  //    max_message_bytes, max_timers, max_processes, max_run_time_ms,
  //    cpu_budget_ms]
  // where a negative entry keeps the default of the kind and 0 means
  // unlimited. Returns null and sets [error] to an error object if the
  // description is invalid. If a new policy is allocated the caller owns it
  // (see [is_owned]) and must hand it to a ProcessGroup.
  static const PrimitivePolicy* from_description(Object* description, Process* process, Object** error);

  // Deletes the policy if it is owned (not one of the standard policies).
  static void release(const PrimitivePolicy* policy);

  Kind kind() const { return kind_; }
  bool is_system() const { return kind_ == SYSTEM; }
  bool is_untrusted() const { return kind_ == UNTRUSTED; }
  bool is_owned() const { return owned_; }

  // Whether messages from processes with this policy are restricted to the
  // system process, the own group and granted targets, and to the RPC
  // message types.
  bool restricts_messaging() const { return kind_ == UNTRUSTED; }

  // Whether HALT 2 (deep sleep) and HALT 3 (reset) may act on the device.
  bool may_halt_device() const { return kind_ != UNTRUSTED; }

  // Whether a process with this policy may send a message of the given type.
  bool may_send_type(int type) const;

  const PolicyQuotas& quotas() const { return quotas_; }

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
  bool owned_ = false;
  PolicyQuotas quotas_ = {};
  const PrimitiveEntry* tables_[Primitive::MODULE_COUNT] = {};
  unsigned lengths_[Primitive::MODULE_COUNT] = {};

  void initialize_all(Kind kind);
  void initialize_untrusted();

  static PrimitivePolicy system_;
  static PrimitivePolicy trusted_;
  static PrimitivePolicy untrusted_;
};

} // namespace toit
