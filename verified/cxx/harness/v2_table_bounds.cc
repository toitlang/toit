// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#include "program.h"
#undef private
#include "v2_method_table.cc"

using namespace toit;

extern Program image;

static void check_last_literal() {
  int count = nondet_int();
  image.literals.length_ = count;
  if (count <= 0) {
    image.literals.array_ = nullptr;
    CXXV_ASSERT(v2_last_table_literal(&image) == nullptr, "an absent literal list needs no storage");
    return;
  }
  CXXV_ASSUME(static_cast<uword>(count) <= UINTPTR_MAX / sizeof(Object*));
  Object** slots = static_cast<Object**>(malloc(static_cast<uword>(count) * sizeof(Object*)));
  CXXV_ASSUME(slots != nullptr);
  image.literals.array_ = slots;
  uword bits = nondet_ulong() & ~uword{1};
  Object* header = reinterpret_cast<Object*>(bits);
  bool heap = nondet_bool();
  Object* object = heap ? static_cast<Object*>(HeapObject::from_address(reinterpret_cast<uword>(&header)))
                        : reinterpret_cast<Object*>(nondet_ulong() & ~uword{1});
  slots[count - 1] = object;
  ByteArray* selected = v2_last_table_literal(&image);
  bool byte_array = heap && ((bits >> 1) & 15) == BYTE_ARRAY_TAG;
  CXXV_ASSERT(selected == (byte_array ? object : nullptr), "select exactly the final byte-array literal");
  free(slots);
}

static void write_field(uint8* dest, uint32 field) {
  dest[0] = static_cast<uint8>(field);
  dest[1] = static_cast<uint8>(field >> 8);
  dest[2] = static_cast<uint8>(field >> 16);
  dest[3] = static_cast<uint8>(field >> 24);
}

static void check_literal() {
  word size = nondet_word();
  word length = nondet_word();
  CXXV_ASSUME(4 <= length && length < V2_MAX_BYTECODES);
  V2TableLiteral table;
  if (size < 16) {
    CXXV_ASSERT(v2_read_table_literal(nullptr, size, length, &table) == V2LiteralStatus::NO_TABLE,
                "reject short literals before reading their data");
    return;
  }
  uint8* data = static_cast<uint8*>(malloc(size));
  CXXV_ASSUME(data != nullptr);
  uint32 marker = nondet_uint();
  uint32 count = nondet_uint();
  uint32 declared_length = nondet_uint();
  write_field(data, marker);
  write_field(data + 4, count);
  write_field(data + 8, declared_length);
  auto result = v2_read_table_literal(data, size, length, &table);
  uint64 required = 16 + static_cast<uint64>(count) * 4;
  if (marker != 0x32544d54) {
    CXXV_ASSERT(result == V2LiteralStatus::NO_TABLE, "require the TMT2 literal marker");
  } else if (declared_length != static_cast<uword>(length)) {
    CXXV_ASSERT(result == V2LiteralStatus::OTHER_BYTECODES, "require the current bytecode length");
  } else if (count == 0 || count > 0xffffff) {
    CXXV_ASSERT(result == V2LiteralStatus::BAD_COUNT && table.count == count, "report the invalid stored count");
  } else if (static_cast<uint64>(size) != required) {
    CXXV_ASSERT(result == V2LiteralStatus::BAD_SIZE, "reject missing or trailing record bytes");
  } else {
    CXXV_ASSERT(result == V2LiteralStatus::OK && table.count == count && table.records == data + 16,
                "return the exact record view");
    CXXV_ASSERT(table.count <= static_cast<uword>(Smi::MAX_SMI_VALUE), "method count fits a tagged integer");
    uword i = nondet_uint();
    CXXV_ASSUME(i < table.count);
    uword first = 16 + 4 * i;
    CXXV_ASSERT(first >= 16 && first + 4 <= static_cast<uword>(size), "four readable bytes per record");
    if (i + 1 < table.count) {
      uword following = 16 + 4 * (i + 1);
      CXXV_ASSERT(following == first + 4 && following + 4 <= static_cast<uword>(size),
                  "lookahead record fits the literal");
    }
  }
  free(data);
}

static void check_header() {
  word length = nondet_word();
  word expected = nondet_word();
  CXXV_ASSUME(4 <= expected && expected <= length && length < V2_MAX_BYTECODES);
  word entry = nondet_uint() >> 8;
  uint8* image = static_cast<uint8*>(malloc(length));
  CXXV_ASSUME(image != nullptr);
  uint8 kind = nondet_uchar();
  uint16 first = nondet_ushort();
  uint16 end = nondet_ushort();
  if (expected < entry && entry < length) {
    image[entry - 1] = kind;
    image[entry - 5] = static_cast<uint8>(first);
    image[entry - 4] = static_cast<uint8>(first >> 8);
    if (entry >= 7) {
      image[entry - 7] = static_cast<uint8>(end);
      image[entry - 6] = static_cast<uint8>(end >> 8);
    }
  }
  auto result = v2_check_header(image, length, entry, expected);
  // Format note 21 lists five canonical kind bytes in numeric order.
  const int sizes[] = {7, 9, 3, 1, 5};
  if (entry <= expected || entry >= length) {
    CXXV_ASSERT(result == V2_HEADER_BAD_ENTRY, "entry must be inside the image after its header");
  } else if (kind >= 5) {
    CXXV_ASSERT(result == V2_HEADER_BAD_KIND, "reject every noncanonical kind byte");
  } else if (entry - expected != sizes[kind]) {
    CXXV_ASSERT(result == V2_HEADER_BAD_POSITION, "header must begin at expected offset");
  } else if (kind != 3 && entry % 2 == 0) {
    CXXV_ASSERT(result == V2_HEADER_EVEN_ENTRY, "every entry but a block's is odd");
  } else {
    bool valid = kind == 0 ? end - first >= 2 :
                 kind == 1 ? (first < end || (first == 65535 && end == 65535)) : true;
    CXXV_ASSERT(result == (valid ? V2_HEADER_OK : V2_HEADER_BAD_RANGE), "canonical receiver interval");
  }
  free(image);
}

static void check_next_header() {
  word length = nondet_word();
  word entry = nondet_word();
  CXXV_ASSUME(4 < entry && entry < length && length < V2_MAX_BYTECODES);
  uint8* image = static_cast<uint8*>(malloc(length));
  CXXV_ASSUME(image != nullptr);
  uint8 record[] = {nondet_uchar(), nondet_uchar(), nondet_uchar(), nondet_uchar()};
  word next = record[1] + 256 * record[2] + 65536 * record[3];
  CXXV_ASSERT(v2_read_u32_le(record) == static_cast<uint32>(next) * 256 + record[0],
              "decode all four little-endian record bytes");
  CXXV_ASSERT(v2_record_entry(record) == next, "record entry is the high 24 bits");
  uint8 kind = nondet_uchar();
  if (entry < next && next <= length) image[next - 1] = kind;

  word end = -1;
  auto result = v2_next_header(image, length, entry, record, &end);
  // Independently decode the four header layouts from format note 21.
  int sizes[] = {7, 9, 3, 1};
  int size = (kind & 7) == 4 ? 5 : sizes[kind & 3];
  if (next <= entry || next > length) {
    CXXV_ASSERT(result == V2_NEXT_BAD_ENTRY, "reject nonincreasing or oversized entry");
  } else if (next - size <= entry) {
    CXXV_ASSERT(result == V2_NEXT_EMPTY_BODY, "reject overlapping header or empty body");
  } else {
    CXXV_ASSERT(result == V2_NEXT_OK && end == next - size, "exact next header");
    CXXV_ASSERT(entry < end && end < next && next <= length, "ordered nonempty method extent");
  }
  free(image);
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  if (nondet_bool()) check_last_literal();
  else if (nondet_bool()) check_literal();
  else if (nondet_bool()) check_header();
  else check_next_header();
}
