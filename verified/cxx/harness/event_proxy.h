// Copyright (C) 2026 Toit contributors.

#pragma once

#include "prelude.h"
#include "objects.h"

namespace cxxv {
using namespace toit;

struct EventProxy {
  uword words[4];
  Object* object;
  bool byte_array;
  bool external;
  word tag;
  bool live;

  void initialize(void* target) {
    bool heap = nondet_bool();
    words[0] = nondet_ulong() & ~uword{1};
    words[1] = nondet_ulong();
    live = nondet_bool();
    words[2] = live ? reinterpret_cast<uword>(target) : 0;
    tag = nondet_word();
    words[3] = static_cast<uword>(tag);
    object = heap ? static_cast<Object*>(HeapObject::from_address(reinterpret_cast<uword>(words)))
                  : reinterpret_cast<Object*>(nondet_ulong() & ~uword{1});
    byte_array = heap && ((words[0] >> 1) & 15) == BYTE_ARRAY_TAG;
    external = words[1] > UINTPTR_MAX / 2;
  }

  bool has_type(word first, word last) const {
    return byte_array && external && first <= tag && tag <= last;
  }
};

}  // namespace cxxv
