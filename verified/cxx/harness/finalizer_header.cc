// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "objects.h"

using namespace toit;

int main() {
  static_assert(sizeof(uword) * 8 == CXXV_WORD_BITS, "target word width");
  // The tag occupies the low bit of the stored Smi. The flag immediately
  // follows its four class-tag bits.
  const uword flag = uword{1} << 5;
  uword bits = nondet_ulong() & ~uword{1};
  Object* slot = reinterpret_cast<Object*>(bits);
  HeapObject* object = HeapObject::from_address(reinterpret_cast<uword>(&slot));
  Object* from_slot = nullptr;
  HeapObject* from = HeapObject::from_address(reinterpret_cast<uword>(&from_slot));
  from->set_forwarding_address(object);

  CXXV_ASSERT(from_slot == object, "forwarding installs the tagged destination");
  CXXV_ASSERT(object->has_active_finalizer() == ((bits & flag) != 0), "reads the header flag");
  CXXV_ASSERT(from->has_active_finalizer() == ((bits & flag) != 0), "reads the forwarded flag");

  if (nondet_bool()) {
    object->set_has_active_finalizer();
    CXXV_ASSERT(reinterpret_cast<uword>(slot) == (bits | flag), "setting preserves all other bits");
  } else {
    object->clear_has_active_finalizer();
    CXXV_ASSERT(reinterpret_cast<uword>(slot) == (bits & ~flag), "clearing preserves all other bits");
  }
  CXXV_ASSERT(from_slot == object, "operations preserve the forwarding pointer");
}
