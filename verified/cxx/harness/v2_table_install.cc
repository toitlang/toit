// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "interpreter_v2.h"
#undef private
#include "flags.h"
#include "objects_inline.h"
#include "program.h"

// Model libc's nonoverlapping byte copy at an arbitrary observed index.
// The boundary reads/writes also check that both full ranges fit.
static const uint8* input;
static size_t input_size;
static size_t observed;
static void* copy_record_bytes(void* dst, const void* src, size_t n) {
  CXXV_ASSERT(src == input && n == input_size, "copy exactly the validated records");
  auto* to = static_cast<uint8*>(dst);
  auto* from = static_cast<const uint8*>(src);
  CXXV_ASSERT(!__ESBMC_same_object(to, from), "copy into separate allocation");
  to[n - 1] = from[n - 1];
  to[observed] = from[observed];
  return dst;
}
#define memcpy copy_record_bytes
// ESBMC takes the successful path for scalar nothrow new. Include its
// permitted null outcome at the two native table allocations.
#undef _new
#define _new nondet_bool() ? nullptr : new (std::nothrow)
#include "v2_method_table.cc"
#undef _new
#undef memcpy

using namespace toit;

// ESBMC implements a delete expression's storage release internally, but
// has no body for an explicit call to the global deallocation function.
void operator delete(void* storage) noexcept { free(storage); }

extern uint8* arbitrary_bytecode_pointer();

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword count = nondet_uint();
  CXXV_ASSUME(count > 0 && count <= 0xffffff);
  uword size = count * 4;
  uint8* storage = static_cast<uint8*>(malloc(size + 3));
  CXXV_ASSUME(storage != nullptr);
  unsigned offset = nondet_uchar() & 3;
  uint8* records = storage + offset;
  uword i = nondet_uint();
  CXXV_ASSUME(i < size);
  uint8 value = nondet_uchar();
  records[i] = value;
  input = records;
  input_size = size;
  observed = i;
  word length = nondet_word();
  CXXV_ASSUME(4 <= length && length < V2_MAX_BYTECODES);
  // Installation carries this pointer through without reading the image.
  uint8* bytes = arbitrary_bytecode_pointer();

  bool report = nondet_bool();
  bool oom = false;
  V2MethodTable* table = V2MethodTable::install(records, count, bytes, length, report ? &oom : nullptr);
  CXXV_ASSERT(oom == (report && table == nullptr), "signal an installation failure when requested");
  if (table != nullptr) {
    CXXV_ASSERT(table->length() == static_cast<word>(count) && table->bytecodes_ == bytes &&
                table->bytecodes_length_ == length, "preserve program views");
    CXXV_ASSERT(table->verified() == 0, "a new table has no verifier acceptance");
    bool untrusted_process = nondet_bool();
    CXXV_ASSERT(!table->runs_verified(untrusted_process), "a fresh table cannot authorize the verified loop");
    bool trusted_rules = nondet_bool();
    table->mark_verified(trusted_rules);
    // A verdict is bound to the policy whose primitive table it was computed
    // with (since 2026-11-26): the untrusted rules and table for an untrusted
    // process, the trusted ones for a trusted process, and never the other
    // (the verified loop gets the process' own policy table, which the
    // verdict must have checked). Until then a verdict of the untrusted
    // rules also admitted a trusted process.
    CXXV_ASSERT(table->runs_verified(untrusted_process) == (untrusted_process != trusted_rules),
                "a verdict admits only a process of the policy it was computed for");
    bool aligned = (reinterpret_cast<uword>(records) & 3) == 0;
    CXXV_ASSERT(table->in_literal() == aligned, "borrow aligned records and own the unaligned copy");
    const uint8* installed = reinterpret_cast<const uint8*>(table->records());
    CXXV_ASSERT((installed == records) == aligned, "record storage matches ownership");
    CXXV_ASSERT(installed[i] == value, "preserve every installed record byte");
    table->~V2MethodTable();
    ::operator delete(table);
  }
  CXXV_ASSERT(records[i] == value, "caller retains the original records after destruction or failure");
  free(storage);
}
