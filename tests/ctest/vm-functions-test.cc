// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// NEGATIVE-TEST

#include "../../src/top.h"

#include "../../src/os.h"

namespace toit {

OS::HeapMemoryRange range;

static void single_page() {
  uint8* range_address = reinterpret_cast<uint8*>(range.address);
  if (range.size < 100 * KB) FATAL("Too tiny");
  uint8* page = reinterpret_cast<uint8*>(OS::allocate_pages(TOIT_PAGE_SIZE));
  if (page < range_address) FATAL("Not in expected area");
  if (page + 4096 > range_address + range.size) FATAL("Not in expected area");
  *page = 42;
  OS::free_pages(page, TOIT_PAGE_SIZE);
}

static void many_pages() {
  uint8* range_min = reinterpret_cast<uint8*>(range.address);
  uint8* range_max = reinterpret_cast<uint8*>(range.address) + range.size;
  uint8* pages[50];
  for (int i = 0; i < 50; i++) {
    pages[i] = reinterpret_cast<uint8*>(OS::allocate_pages(TOIT_PAGE_SIZE));
    pages[i][i] = 42;
    if (pages[i] < range_min) FATAL("Page not in range");
    if (pages[i] + 4096 > range_max) FATAL("Page not in range");
  }
  for (int i = 0; i < 50; i++) {
    OS::free_pages(pages[i], TOIT_PAGE_SIZE);
  }
}

void reentrant_locking() {
  Mutex* m1 = OS::allocate_mutex(1, "m1");
  Mutex* m2 = OS::allocate_mutex(2, "m2");
  Mutex* m3 = OS::allocate_mutex(3, "m3");

  { Locker outer(m1);
    { Locker inner(m1);
    }
    Locker inbetween(m3);
    { Locker inner(m1);
      // Trying to lock m2 here is illegal.
      USE(m2);
#ifdef NEGATIVE_TEST
      Locker inner2(m2);
#endif
    }
  }
  { Locker outer(m1);
  }
}

int main(int argc, char **argv) {
  OS::set_up();
  range = OS::get_heap_memory_range();
  single_page();
  many_pages();
  reentrant_locking();

  OS::tear_down();
  return 0;
}

}  // namespace toit.

int main(int argc, char **argv) {
  return toit::main(argc, argv);
}
