// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include "interpreter_v2.h"
#include "objects_inline.h"
#include "program.h"

// Diagnostic output is outside the loader's return and ownership contract.
static int discard_diagnostic(FILE*, const char*, ...) { return 0; }

namespace toit {
#define fprintf discard_diagnostic
#include "v2_compute_method_table.h"
#undef fprintf

extern Program source_program;
extern V2MethodTable installed_table;
extern uint8* arbitrary_byte_pointer();

enum class Stage { START, SELECTED, PARSED, VALIDATED, INSTALLED };
static Stage stage;
static const uint8* image;
static word image_length;
static ByteArray* selected;
static const uint8* payload;
static word payload_length;
static V2LiteralStatus literal_status;
static const uint8* parsed_records;
static uword record_count;
static bool valid;
static bool allocation_failed;
static bool* failure_flag;

// Each callee can give any of its verified outcomes. Check its arguments
// and the earlier calls before publishing its result to the caller.
static ByteArray* v2_last_table_literal(Program* program) {
  CXXV_ASSERT(stage == Stage::START && program == &source_program, "select from the source program");
  stage = Stage::SELECTED;
  return selected;
}

static V2LiteralStatus v2_read_table_literal(const uint8* data, word size, word length, V2TableLiteral* table) {
  CXXV_ASSERT(stage == Stage::SELECTED && selected != nullptr, "parse only the selected literal");
  CXXV_ASSERT(data == payload && size == payload_length && length == image_length,
              "parse the selected byte view for the current image");
  stage = Stage::PARSED;
  if (literal_status == V2LiteralStatus::BAD_COUNT || literal_status == V2LiteralStatus::OK) {
    table->count = record_count;
  }
  if (literal_status == V2LiteralStatus::OK) table->records = parsed_records;
  return literal_status;
}

static const char* v2_validate_records(const uint8* bytes, word length, const uint8* table,
                                       uword count, word* detail) {
  CXXV_ASSERT(stage == Stage::PARSED && literal_status == V2LiteralStatus::OK, "validate only an accepted literal");
  CXXV_ASSERT(bytes == image && length == image_length && table == parsed_records && count == record_count,
              "validate the exact parsed records against the source image");
  stage = Stage::VALIDATED;
  if (valid) return nullptr;
  *detail = nondet_word();
  return "invalid record";
}

V2MethodTable* V2MethodTable::install(const uint8* table, uword count, const uint8* bytes,
                                      word length, bool* oom) {
  CXXV_ASSERT(stage == Stage::VALIDATED && valid, "install only after successful record validation");
  CXXV_ASSERT(bytes == image && length == image_length && table == parsed_records && count == record_count,
              "install the exact records and image that passed validation");
  CXXV_ASSERT(oom == failure_flag && (oom == nullptr || !*oom), "forward the cleared optional failure flag");
  stage = Stage::INSTALLED;
  if (allocation_failed && oom != nullptr) *oom = true;
  return allocation_failed ? nullptr : &installed_table;
}
}  // namespace toit

using namespace toit;

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  image_length = nondet_word();
  CXXV_ASSUME(image_length >= 0);
  // Only the four tag bytes are read by compute itself.
  uint8 tag[] = {nondet_uchar(), nondet_uchar(), nondet_uchar(), nondet_uchar()};
  uint8* bytecodes = image_length == 0 && nondet_bool() ? nullptr : tag;
  image = bytecodes;
  source_program.bytecodes = List<uint8>(bytecodes, image_length);
  bool eligible = image_length >= 4 && image_length < 0x1000000 &&
                  tag[0] == 'T' && tag[1] == 'B' && tag[2] == 'C' && tag[3] == '2' &&
                  (reinterpret_cast<uword>(bytecodes) & 1) == 0;

  uword object[4] = {2 * BYTE_ARRAY_TAG, 0, 0, RawByteTag};
  auto* array = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(object)));
  payload_length = nondet_word();
  CXXV_ASSUME(payload_length >= 0);
  uint8* external = nullptr;
  if (nondet_bool()) {
    payload = reinterpret_cast<uint8*>(object + 2);
    object[1] = static_cast<uword>(payload_length);
  } else {
    external = static_cast<uint8*>(malloc(payload_length == 0 ? 1 : payload_length));
    CXXV_ASSUME(external != nullptr || payload_length == 0);
    payload = external;
    object[1] = static_cast<uword>(-1 - payload_length);
    object[2] = reinterpret_cast<uword>(payload);
  }
  selected = nondet_bool() ? array : nullptr;
  int status = nondet_int();
  CXXV_ASSUME(status >= 0 && status <= static_cast<int>(V2LiteralStatus::BAD_SIZE));
  literal_status = static_cast<V2LiteralStatus>(status);
  parsed_records = arbitrary_byte_pointer();
  record_count = nondet_uint();
  valid = nondet_bool();
  allocation_failed = nondet_bool();
  bool oom = nondet_bool();
  bool original = oom;
  failure_flag = nondet_bool() ? &oom : nullptr;

  auto* result = V2MethodTable::compute(&source_program, failure_flag);
  Stage expected;
  if (!eligible) expected = Stage::START;
  else if (selected == nullptr) expected = Stage::SELECTED;
  else if (literal_status != V2LiteralStatus::OK) expected = Stage::PARSED;
  else if (!valid) expected = Stage::VALIDATED;
  else expected = Stage::INSTALLED;
  CXXV_ASSERT(stage == expected, "every rejection stops at the corresponding check");
  CXXV_ASSERT(result == (expected == Stage::INSTALLED && !allocation_failed ? &installed_table : nullptr),
              "return exactly the installed table or null");
  CXXV_ASSERT(oom == (failure_flag == nullptr ? original : expected == Stage::INSTALLED && allocation_failed),
              "report only installation allocation failure");
  free(external);
}
