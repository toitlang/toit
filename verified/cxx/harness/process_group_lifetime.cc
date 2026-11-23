// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "process_group.cc"
#undef private

using namespace toit;
extern ProcessGroup group;
extern Process first, second, third;

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "only registered processes start teardown");
  abort();
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target width");
  // An arbitrary number of other destructors can already hold this group.
  uword prior = nondet_ulong();
  CXXV_ASSUME(prior <= UINTPTR_MAX - 2);
  group.pending_teardowns_ = prior;
  new (&group.processes_) ProcessListFromProcessGroup();
  group.add(&first);
  group.add(&second);
  Process* a = nondet_bool() ? &first : &second;
  Process* b = a == &first ? &second : &first;
  group.begin_process_teardown(a);
  CXXV_ASSERT(group.pending_teardowns_ == prior + 1 && group.processes_.first() == b,
              "unregister the exiting member while retaining the other and pinning the group");
  bool overlap = nondet_bool();
  if (overlap) group.begin_process_teardown(b);
  CXXV_ASSERT(!group.finish_process_teardown(),
              "the first destructor to finish retains the group for a live or tearing-down peer");
  if (!overlap) group.begin_process_teardown(b);
  bool joined = nondet_bool();
  if (joined) group.add(&third);
  bool release = group.finish_process_teardown();
  CXXV_ASSERT(group.pending_teardowns_ == prior && release == (prior == 0 && !joined),
              "release only after every destructor finishes and the current member list is empty");
  CXXV_ASSERT(group.processes_.first() == (joined ? &third : nullptr), "retain later registrations");
}
