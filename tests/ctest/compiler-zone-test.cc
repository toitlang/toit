// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include <string>
#include <thread>
#include <vector>

#include "../../src/compiler/list.h"
#include "../../src/compiler/zone.h"

namespace toit {
namespace compiler {

static std::vector<int> destroyed;

struct Tracked {
  explicit Tracked(int id) : id(id), contents(1000, 'x') {}
  ~Tracked() { destroyed.push_back(id); }
  int id;
  std::string contents;
};

static std::vector<const void*> destroyed_elements;

struct Element {
  ~Element() { destroyed_elements.push_back(this); }
  int value;
  std::string contents;
};

static void check(bool condition) {
  if (!condition) FATAL("Compiler zone lifetime test failed");
}

static void test() {
  AllowThrowingNew allow;
  {
    Zone outer;
    auto first = zone_new<Tracked>(1);
    auto str = outer.strdup("survives nested zones and chunk growth");
    auto list = ListBuilder<std::string>::build(std::string(1000, 'a'));
    {
      Zone inner;
      zone_new<Tracked>(2);
      auto last = zone_new<Tracked>(3);
      check(last->contents.size() == 1000);
      // A large allocation must not invalidate earlier storage.
      memset(inner.allocate(200000), 0xab, 200000);
      auto aligned = inner.allocate(sizeof(std::max_align_t));
      check(reinterpret_cast<uintptr_t>(aligned) % alignof(std::max_align_t) == 0);
      inner.own_malloc(::strdup("adopted malloc storage"));
    }
    check(destroyed.size() == 2 && destroyed[0] == 3 && destroyed[1] == 2);
    check(Zone::current() == &outer);
    check(first->contents[999] == 'x');
    check(list[0].size() == 1000 && list[0][999] == 'a');
    check(strcmp(str, "survives nested zones and chunk growth") == 0);

    std::thread other([&] {
      Zone independent;
      check(Zone::current() == &independent);
      check(strcmp(independent.strdup("thread"), "thread") == 0);
    });
    other.join();
    check(Zone::current() == &outer);
  }
  check(destroyed.size() == 3 && destroyed[2] == 1);

  const void* element_addresses[3];
  {
    Zone zone;
    auto ints = ListBuilder<int>::allocate(16);
    for (int i = 0; i < 16; i++) check(ints[i] == 0);
    auto elements = ListBuilder<Element>::allocate(3);
    for (int i = 0; i < 3; i++) check(elements[i].value == 0 && elements[i].contents.empty());
    elements[2].contents = std::string(1000, 'e');
    for (int i = 0; i < 3; i++) element_addresses[i] = &elements[i];
    auto empty = ListBuilder<Element>::allocate(0);
    check(empty.length() == 0);
    check(destroyed_elements.empty());
  }
  // Elements are destroyed in reverse order.
  check(destroyed_elements.size() == 3);
  for (int i = 0; i < 3; i++) check(destroyed_elements[i] == element_addresses[2 - i]);
}

} // namespace compiler
} // namespace toit

int main(int argc, char** argv) {
  toit::compiler::test();
  return 0;
}
