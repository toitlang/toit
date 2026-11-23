// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "heap.h"
static uword arena[6];

// Verify the native call's arguments before passing those exact constants
// to memcpy. This avoids a symbolic byte-copy loop over variable addresses.
static void copy_leaf(void* dst, const void* src, size_t bytes) {
  CXXV_ASSERT(dst == arena + 2 && src == arena && bytes == 2 * sizeof(uword),
              "copy exactly the allocated leaf from its original address");
  memcpy(arena + 2, arena, 2 * sizeof(uword));
}
#define memcpy copy_leaf
#include "third_party/dartino/two_space_heap.cc"
#undef memcpy
#undef protected
#undef private

using namespace toit;
namespace toit {
#include "monitor_root.inc"
}
extern ObjectNotifier monitor;
extern Process owner;
extern ObjectNotifyMessage pending;

// Each mode supplies distinct young and old regions. Keep the successful
// allocation at the same address so the copy contract is identical.
enum { YOUNG, PROMOTED, PROMOTION_FAILED };
static constexpr bool attempt_promotion = CXXV_MONITOR_MODE != YOUNG;
static constexpr bool promoted = CXXV_MONITOR_MODE == PROMOTED;
extern OldSpace old_space;
extern ScavengeVisitor visitor;
extern Program image;
static unsigned copies, attempts;
void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "a valid fixed-size monitor instance never reaches the fatal size path");
  abort();
}

static HeapObject* leaf() { return HeapObject::from_address(reinterpret_cast<uword>(arena)); }
static HeapObject* survivor() { return HeapObject::from_address(reinterpret_cast<uword>(arena + 2)); }
uword SemiSpace::allocate(uword bytes) {
  CXXV_ASSERT(this == visitor.to_space() && !promoted && bytes == 2 * WORD_SIZE && copies == 0 &&
              attempts == static_cast<unsigned>(attempt_promotion),
              "reserve exactly one destination for the monitor object");
  ++copies;
  return reinterpret_cast<uword>(arena + 2);
}
uword OldSpace::allocate(uword bytes) {
  CXXV_ASSERT(this == &old_space && bytes == 2 * WORD_SIZE && attempt_promotion && attempts == 0 && copies == 0,
              "request one exact-size promotion before any young allocation");
  ++attempts;
  if (!promoted) return 0;
  ++copies;
  return reinterpret_cast<uword>(arena + 2);
}
class MonitorVisitor : public RootCallback {
 public:
  void do_roots(Object** slot, word count) override {
    CXXV_ASSERT(!visited && slot == &monitor.object_ && count == 1 && *slot == leaf(),
                "visit exactly the registered monitor slot");
    visited = true;
    visitor.ScavengeVisitor::do_roots(slot, 1);
  }
  bool visited = false;
};

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  monitor.process_ = &owner;
  monitor.set_message(&pending);
  monitor.update_object(leaf());
  visitor.program_ = &image;
  visitor.from_start_ = reinterpret_cast<uword>(arena);
  visitor.to_start_ = reinterpret_cast<uword>(arena + (promoted ? 4 : 2));
  visitor.old_ = &old_space;
  visitor.from_size_ = visitor.to_size_ = 2 * WORD_SIZE;
  visitor.water_mark_ = visitor.from_start_ + (attempt_promotion ? WORD_SIZE : 0);
  bool pending_gc = nondet_bool();
  visitor.trigger_old_space_gc_ = pending_gc;
  uint8 global_card = nondet_uchar(), monitor_card = nondet_uchar();
  uint8 prior_global = global_card, prior_monitor = monitor_card;
  visitor.set_record_new_space_pointers(&global_card);
  uint16 classes[] = {Program::compute_class_bits(INSTANCE_TAG, 3 * WORD_SIZE),
                      Program::compute_class_bits(INSTANCE_TAG, 2 * WORD_SIZE)};
  image.class_bits = List<uint16>(classes, 2);
  leaf()->_set_header(Smi::from(1), INSTANCE_TAG);
  arena[1] = reinterpret_cast<uword>(Smi::from(nondet_word() >> 1));
  uword payload = arena[1];
  uword header = arena[0];
  // Process globals precede monitor roots in ObjectHeap::iterate_roots.
  bool alias = nondet_bool();
  Object* global = alias ? static_cast<Object*>(leaf()) : Smi::from(0);
  visitor.ScavengeVisitor::do_roots(&global, 1);
  visitor.set_record_new_space_pointers(&monitor_card);
  MonitorVisitor cb;
  monitor.roots_do(&cb);
  CXXV_ASSERT(cb.visited && monitor.process() == &owner && monitor.message() == &pending,
              "preserve the receiver and mailbox message during relocation");
  CXXV_ASSERT(attempts == static_cast<unsigned>(attempt_promotion) &&
              visitor.trigger_old_space_gc() == (pending_gc || CXXV_MONITOR_MODE == PROMOTION_FAILED),
              "preserve a prior GC request and request old-space collection on promotion failure");
  CXXV_ASSERT(global_card == (alias && !promoted ? GcMetadata::NEW_SPACE_POINTERS : prior_global) &&
              monitor_card == (!promoted ? GcMetadata::NEW_SPACE_POINTERS : prior_monitor),
              "record each young reference on its own card even when already forwarded");
  CXXV_ASSERT(monitor.object() == survivor() && global == (alias ? static_cast<Object*>(survivor()) : Smi::from(0)) &&
              copies == 1 && leaf()->forwarding_address() == survivor() &&
              arena[2] == header && arena[3] == payload && arena[1] == payload,
              "forward both aliases to a single intact copy");
}
