// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// The method table of format-2 programs (V2MethodTable, interpreter_v2.h):
// the records of the table literal the compiler appends, and the method
// headers they point at (format note 21). Without dependencies on the VM's
// heap and scheduler, so that the compiler links it too.

#include "interpreter_v2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flags.h"
#include "objects_inline.h"
#include "program.h"

namespace toit {
static const int V2_TAG_SIZE = 4;

V2MethodTable::~V2MethodTable() {
  if (owned_) free(const_cast<uint32*>(records_));
}

static_assert(V2_TAG_SIZE == 4 && V2_RECORD_ENTRY_SHIFT == 8, "method table proof constants");
#include "v2_validate_records.h"

static uint32 v2_read_u32_le(const uint8* p) {
  return static_cast<uint32>(p[0]) | (static_cast<uint32>(p[1]) << 8) |
         (static_cast<uint32>(p[2]) << 16) | (static_cast<uint32>(p[3]) << 24);
}

static word v2_record_entry(const uint8* p) {
  return v2_read_u32_le(p) >> V2_RECORD_ENTRY_SHIFT;
}

static uint16 v2_read_u16_le(const uint8* p) {
  return static_cast<uint16>(p[0] | (p[1] << 8));
}

#include "v2_compute_method_table.h"

static ByteArray* v2_last_table_literal(Program* program) {
  // The table has length -1 before the compiler creates it.
  int count = program->literals.length();
  if (count <= 0) return null;
  Object* last = program->literals.at(count - 1);
  return is_byte_array(last) ? ByteArray::cast(last) : null;
}

static V2LiteralStatus v2_read_table_literal(const uint8* data, word size, word length, V2TableLiteral* table) {
  if (size < V2MethodTable::TABLE_LITERAL_HEADER_SIZE ||
      v2_read_u32_le(data) != V2MethodTable::TABLE_LITERAL_MARKER) {
    return V2LiteralStatus::NO_TABLE;
  }
  table->count = v2_read_u32_le(data + 4);
  if (v2_read_u32_le(data + 8) != static_cast<uword>(length)) return V2LiteralStatus::OTHER_BYTECODES;
  if (table->count == 0 || table->count >= 0x1000000) return V2LiteralStatus::BAD_COUNT;
  if (static_cast<uword>(size - V2MethodTable::TABLE_LITERAL_HEADER_SIZE) != table->count * sizeof(uint32)) {
    return V2LiteralStatus::BAD_SIZE;
  }
  table->records = data + V2MethodTable::TABLE_LITERAL_HEADER_SIZE;
  return V2LiteralStatus::OK;
}

static V2Header v2_check_header(const uint8* bytes, word length, word entry, word expected) {
  if (entry <= expected || entry >= length) return V2_HEADER_BAD_ENTRY;
  int kind_byte = bytes[entry - 1];
  int kind = kind_byte & V2_KIND_MASK;
  if ((kind_byte & ~(V2_KIND_MASK | V2_KIND_SINGLE)) != 0 ||
      ((kind_byte & V2_KIND_SINGLE) != 0 && kind != V2_KIND_METHOD)) {
    return V2_HEADER_BAD_KIND;
  }
  if (entry - V2MethodTable::header_size(kind_byte) != expected) return V2_HEADER_BAD_POSITION;
  if (kind == V2_KIND_METHOD || kind == V2_KIND_FIELD_ACCESSOR) {
    uint16 start = v2_read_u16_le(bytes + entry - V2_RECV_START_BACK);
    bool ok = true;
    if (kind == V2_KIND_METHOD && (kind_byte & V2_KIND_SINGLE) == 0) {
      // At least two classes (one class or none is the short form).
      ok = start < V2_NO_VALUE && start + 1 < v2_read_u16_le(bytes + entry - V2_RECV_END_BACK);
    } else if (kind == V2_KIND_FIELD_ACCESSOR) {
      uint16 end = v2_read_u16_le(bytes + entry - V2_RECV_END_BACK);
      ok = start == V2_NO_VALUE ? end == V2_NO_VALUE : start < end;
    }
    if (!ok) return V2_HEADER_BAD_RANGE;
  }
  return V2_HEADER_OK;
}

// Compute the exclusive end of a non-final method's body. Delay the
// header read until the next entry has been checked against the image.
static V2NextHeader v2_next_header(const uint8* bytes, word length, word entry,
                                   const uint8* next_record, word* end) {
  word next = v2_record_entry(next_record);
  if (next <= entry || next > length) return V2_NEXT_BAD_ENTRY;
  word header = next - V2MethodTable::header_size(bytes[next - 1]);
  if (header <= entry) return V2_NEXT_EMPTY_BODY;
  *end = header;
  return V2_NEXT_OK;
}

// Format note 21 and `vdecode` in verified/spec/src/v2/vprog.rs: the
// fields of the header that ends at the entry, each at a fixed distance
// from it; the body ends at the next method's header. Only for a table
// compute() accepted.
V2Method V2MethodTable::at(word index) const {
  V2Method m;
  uint32 record = records_[index];
  word entry = record >> V2_RECORD_ENTRY_SHIFT;
  int kind_byte = bytecodes_[entry - 1];
  int kind = kind_byte & V2_KIND_MASK;
  m.entry = entry;
  m.arity = record & V2_RECORD_ARITY_MASK;
  m.kind = kind;
  m.selector = V2_NO_VALUE;
  m.aux = 0;
  m.recv_start = V2_NO_VALUE;
  m.recv_end = V2_NO_VALUE;
  if (kind == V2_KIND_METHOD || kind == V2_KIND_FIELD_ACCESSOR) {
    m.selector = v2_read_u16_le(bytecodes_ + entry - V2_SELECTOR_BACK);
    m.recv_start = v2_read_u16_le(bytecodes_ + entry - V2_RECV_START_BACK);
    if ((kind_byte & V2_KIND_SINGLE) == 0) {
      m.recv_end = v2_read_u16_le(bytecodes_ + entry - V2_RECV_END_BACK);
    } else if (m.recv_start < V2_NO_VALUE) {
      m.recv_end = m.recv_start + 1;
    }
    if (kind == V2_KIND_FIELD_ACCESSOR) m.aux = v2_read_u16_le(bytecodes_ + entry - V2_ACCESSOR_AUX_BACK);
  } else if (kind == V2_KIND_LAMBDA) {
    m.aux = v2_read_u16_le(bytecodes_ + entry - V2_LAMBDA_AUX_BACK);
  }
  m.end_ = index + 1 < length_ ? header_of(index + 1) : bytecodes_length_;
  return m;
}

uint8* V2MethodTable::encode_table_literal(const uint32* records, word count, word bytecodes_length,
                                           word* length) {
  word size = TABLE_LITERAL_HEADER_SIZE + count * sizeof(uint32);
  uint8* result = unvoid_cast<uint8*>(malloc(size));
  if (result != null) {
    uint32 header[4] = {
      TABLE_LITERAL_MARKER,
      static_cast<uint32>(count),
      static_cast<uint32>(bytecodes_length),
      0
    };
    // Hosts and devices are little endian (records are copied as is).
    memcpy(result, header, sizeof(header));
    memcpy(result + TABLE_LITERAL_HEADER_SIZE, records, count * sizeof(uint32));
    *length = size;
  }
  return result;
}

bool V2MethodTable::trusted_on_verified_loop() {
  if (!checked_loop_linked()) return true;
  static int enabled = -1;
  if (enabled < 0) {
    const char* env = getenv("TOIT_TRUSTED_CHECKED_LOOP");
    enabled = (env != null && env[0] != '\0' && env[0] != '0') ? 0 : 1;
  }
  return enabled == 1;
}

V2MethodTable* V2MethodTable::install(const uint8* records, uword count, const uint8* bytes,
                                     word length, bool* out_of_memory) {
  // The records are read as u32: the bytes must be aligned (program heap
  // and off-heap allocations are word aligned; copied otherwise).
  if ((reinterpret_cast<uword>(records) & 3) == 0) {
    V2MethodTable* table = _new V2MethodTable(reinterpret_cast<const uint32*>(records), count, bytes, length, false);
    if (table == null && out_of_memory != null) *out_of_memory = true;
    return table;
  }
  uint32* copy = unvoid_cast<uint32*>(malloc(count * sizeof(uint32)));
  if (copy == null) {
    if (out_of_memory != null) *out_of_memory = true;
    return null;
  }
  memcpy(copy, records, count * sizeof(uint32));
  V2MethodTable* table = _new V2MethodTable(copy, count, bytes, length, true);
  if (table == null) {
    free(copy);
    if (out_of_memory != null) *out_of_memory = true;
  }
  return table;
}

bool V2MethodTable::untrusted_format1_allowed() {
  if (Flags::untrusted_format1) return true;
  const char* env = getenv("TOIT_UNTRUSTED_FORMAT1");
  return env != null && strcmp(env, "1") == 0;
}

word V2MethodTable::entry_method(Program* program, int entry_point_index) const {
  int d = program->entry_point_indexes()[entry_point_index];
  if (d < 0 || d >= program->dispatch_table.length()) return -1;
  word m = program->dispatch_table[d];
  return is_valid(m) ? m : -1;
}

word V2MethodTable::index_of_entry(word entry) const {
  word low = 0;
  word high = length_ - 1;
  while (low <= high) {
    word mid = low + (high - low) / 2;
    word e = entry_of(mid);
    if (e == entry) return mid;
    if (e < entry) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return -1;
}

}  // namespace toit
