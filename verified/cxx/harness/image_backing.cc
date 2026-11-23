// Copyright (C) 2026 Toit contributors.

#ifdef CXXV_IMAGE_DEBUG
#undef TOIT_DEPLOY
#define TOIT_DEBUG
#endif
#include "prelude.h"
#include "os.h"
#include "utils.h"
#include "process.h"
#include "program.h"
#include "snapshot.h"
#include "vm.h"
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

extern "C" char* realpath(const char*, char*);
extern "C" int setenv(const char*, const char*, int);
extern "C" int unsetenv(const char*);

static size_t requested;
static uint8* backing;
static bool allocated, released;
static bool image_mode;
static unsigned protection_calls;
#ifdef TOIT_DEBUG
static bool initialized, poisoned;
static uint8* image_start;
static size_t logical_size;

static void* observe_fill(void* dst, int byte, size_t count) {
  if (byte == 0xcd) {
    CXXV_ASSERT(allocated && !initialized && backing != nullptr && dst == backing && count == requested,
                "initialize only a successful complete backing allocation");
    initialized = true;
  } else {
    CXXV_ASSERT(byte == 0xde && initialized && !poisoned && !released && dst == image_start && count == logical_size,
                "poison only the logical image before freeing its backing");
    CXXV_ASSERT(!image_mode || count == 0 || protection_calls == 2, "restore image write access before poisoning");
    poisoned = true;
  }
  return dst;
}
#endif

static void* reserve_memory(size_t n) {
  CXXV_ASSERT(!allocated && n != 0, "request one nonempty backing allocation");
  requested = n;
  allocated = true;
  if (nondet_bool()) return nullptr;
  backing = static_cast<uint8*>(malloc(n));
  return backing;
}

static void release_memory(void* p) {
  CXXV_ASSERT(backing != nullptr && p == backing && !released, "release the original backing exactly once");
#ifdef TOIT_DEBUG
  CXXV_ASSERT(poisoned, "poison successful allocations before release");
#endif
  released = true;
  free(p);
}

#define malloc reserve_memory
#define free release_memory
#ifdef TOIT_DEBUG
#define memset observe_fill
#endif
#include "os.cc"
#ifdef TOIT_DEBUG
#undef memset
#endif
#undef free
#undef malloc

using namespace toit;

#ifdef TOIT_DEBUG
void toit::fail(const char*, int, const char*, ...) {
  CXXV_ASSERT(false, "valid image operations satisfy native debug assertions");
  abort();
}
#endif

static unsigned page_shift;
static size_t image_bytes;

static int page_size() { return 1 << page_shift; }

static int protect_image(void* address, size_t size, int mode) {
  CXXV_ASSERT(image_mode && !released && backing != nullptr && size != 0 && size == image_bytes,
              "protect only the live nonempty image");
  size_t offset = reinterpret_cast<uword>(address) - reinterpret_cast<uword>(backing);
  size_t mask = page_size() - 1;
  CXXV_ASSERT((reinterpret_cast<uword>(address) & mask) == 0 && offset < requested &&
              size <= requested - offset && ((-size) & mask) <= requested - offset - size,
              "every OS page covered by mprotect lies inside the malloc grant");
  CXXV_ASSERT(mode == (protection_calls == 0 ? PROT_READ : PROT_READ | PROT_WRITE),
              "publish read-only then restore write permission before release");
  ++protection_calls;
  return 0;
}

#define getpagesize page_size
#define mprotect protect_image
#include "os_posix.cc"
#undef mprotect
#undef getpagesize

static void check_owned_image() {
  image_mode = true;
  page_shift = nondet_uint();
  CXXV_ASSUME(page_shift < 31);
  int bytes = nondet_int();
  CXXV_ASSUME(bytes >= 0);
  image_bytes = bytes;
  auto* memory = new ProtectableAlignedMemory(image_bytes, TOIT_PAGE_SIZE);
  ProgramImage image(memory);
  bool owns = backing != nullptr;
  CXXV_ASSERT(image.byte_size() == bytes && image.is_valid() == owns &&
              image.address() == memory->address() && image.memory() == memory,
              "the program image publishes the same owner, address and logical size");
  if (owns) {
    uword raw = reinterpret_cast<uword>(backing);
    uword root = nondet_ulong();
    CXXV_ASSUME(root != 0 && root % WORD_SIZE == 0);
    // The malloc grant and a live movable object occupy disjoint storage.
    CXXV_ASSUME(root < raw || root - raw >= requested);
    uword tagged = reinterpret_cast<uword>(HeapObject::from_address(root));
    uword begin = reinterpret_cast<uword>(image.begin());
    uword end = reinterpret_cast<uword>(image.end());
    CXXV_ASSERT(begin >= raw && end >= begin && end - raw <= requested &&
                (tagged < begin || tagged >= end),
                "the tagged reference to a separate object lies outside every bytecode slice of the image");
  }
#ifdef TOIT_DEBUG
  image_start = static_cast<uint8*>(image.address());
  logical_size = image_bytes;
#endif
  memory->mark_read_only();
  unsigned expected = owns && bytes != 0 ? 1 : 0;
  CXXV_ASSERT(protection_calls == expected && !released, "retain the backing after publication");
  image.release();
  CXXV_ASSERT(protection_calls == 2 * expected && released == owns &&
              !image.is_valid() && image.memory() == nullptr,
              "release restores write permission and invalidates the owning image");
  image.release();
  CXXV_ASSERT(protection_calls == 2 * expected && released == owns, "repeat release is harmless");
}

int main() {
  static_assert(CXXV_WORD_BITS == WORD_BIT_SIZE, "target width");
  if (nondet_bool()) {
    check_owned_image();
    return 0;
  }
  size_t bytes = nondet_ulong(), alignment = nondet_ulong();
  {
    AlignedMemory image(bytes, alignment);
    CXXV_ASSERT(image.byte_size() == bytes, "report the logical image extent");
    bool power = alignment != 0 && (alignment & (alignment - 1)) == 0;
    if (!power) {
      CXXV_ASSERT(!allocated, "reject invalid alignment before allocation");
    } else {
      size_t remainder = bytes % alignment;
      size_t pad = remainder == 0 ? 0 : alignment - remainder;
      bool fits = bytes <= SIZE_MAX - alignment && pad <= SIZE_MAX - alignment - bytes;
      CXXV_ASSERT(allocated == fits, "reserve exactly when the rounded extent and alignment slack fit");
      if (allocated) CXXV_ASSERT(requested == bytes + pad + alignment, "reserve all trailing page padding");
    }
    if (backing == nullptr) {
      CXXV_ASSERT(image.address() == nullptr, "failure publishes no image address");
    } else {
      auto* start = static_cast<uint8*>(image.address());
      size_t offset = reinterpret_cast<uword>(start) - reinterpret_cast<uword>(backing);
      CXXV_ASSERT(offset < alignment && start == backing + offset &&
                  (reinterpret_cast<uword>(start) & (alignment - 1)) == 0,
                  "return the first aligned address in the backing allocation");
      size_t available = requested - offset;
      CXXV_ASSERT(bytes <= available && (bytes % alignment == 0 || alignment - bytes % alignment <= available - bytes),
                  "the image and its last protected page stay inside the backing");
    }
#ifdef TOIT_DEBUG
    image_start = static_cast<uint8*>(image.address());
    logical_size = bytes;
#endif
    CXXV_ASSERT(!released, "retain ownership while the image is live");
  }
  CXXV_ASSERT(released == (backing != nullptr), "destruction releases every successful allocation");
}
