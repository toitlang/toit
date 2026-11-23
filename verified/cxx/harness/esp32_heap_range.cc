// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#undef TOIT_FREERTOS
#include "mutex.h"
#define TOIT_FREERTOS
#define TOIT_ESP32
#define private public
#include "os.h"
#undef private
#include "multi_heap.h"
#include "range_constants.inc"

using namespace toit;

static multi_heap_info_t internal_info, external_info;
static unsigned queries, revision_queries;
static int revision;
static int efuse_hal_chip_revision() {
  ++revision_queries;
  return revision;
}
static void heap_caps_get_info(multi_heap_info_t* info, uint32_t caps) {
  bool probe = queries++ == 0;
  CXXV_ASSERT(caps == (probe ? MALLOC_CAP_8BIT | MALLOC_CAP_SPIRAM :
                               MALLOC_CAP_8BIT | MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
              "probe external RAM first and request internal bounds only on fallback");
  *info = probe ? external_info : internal_info;
}

static uword cache_bytes;
#define CONFIG_CACHE_L2_CACHE_SIZE cache_bytes
namespace toit {
#define printf(...) ((void)0)
#include "heap_range.inc"
#undef printf
}

static multi_heap_info_t reported_range() {
  multi_heap_info_t info{};
  uword low = nondet_uint();
  uword high = nondet_uint();
  CXXV_ASSUME(low == 0 || low <= high);
  info.lowest_address = reinterpret_cast<void*>(low);
  info.highest_address = reinterpret_cast<void*>(high);
  return info;
}

int main() {
  static_assert(WORD_BIT_SIZE == 32, "ESP32 address width");
  external_info = reported_range();
  internal_info = reported_range();
  revision = nondet_word();
  cache_bytes = nondet_uint();
  CXXV_ASSUME(cache_bytes < SOC_DRAM_HIGH - SOC_DRAM_LOW);
  OS::use_spiram_for_heap_ = nondet_bool();
  OS::use_spiram_for_metadata_ = nondet_bool();

  bool detected = external_info.lowest_address != nullptr;
  bool check_revision = detected && CXXV_CHECK_REVISION;
  bool external = detected && CXXV_ALLOW_EXTERNAL && (!check_revision || revision >= 300);
  OS::HeapMemoryRange range = OS::get_heap_memory_range();
  CXXV_ASSERT(revision_queries == static_cast<unsigned>(check_revision), "apply the chip revision check when required");
  CXXV_ASSERT(queries == (external ? 1u : 2u), "use the probe bounds or obtain internal bounds");
  CXXV_ASSERT(OS::use_spiram_for_heap() == external && OS::use_spiram_for_metadata() == external,
              "select the same permitted RAM for pages and metadata on every initialization");
  multi_heap_info_t selected = external ? external_info : internal_info;
  uword low = SOC_DRAM_LOW;
  uword high = SOC_DRAM_HIGH - (CXXV_P4 ? cache_bytes : 0);
  if (selected.lowest_address) {
    low = reinterpret_cast<uword>(selected.lowest_address);
    high = reinterpret_cast<uword>(selected.highest_address);
  }
  uword base = reinterpret_cast<uword>(range.address);
  CXXV_ASSERT(base == low && static_cast<uint64_t>(base) + range.size == high,
              "return the exact selected range with any fallback cache reservation excluded");
}
