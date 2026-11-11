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
// decoding the method headers and the table literal the compiler appends.
// Without dependencies on the VM's heap and scheduler, so that the
// compiler links it too.

#include "interpreter_v2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flags.h"
#include "objects_inline.h"
#include "program.h"

namespace toit {
static const int V2_TAG_SIZE = 4;
static const int V2_KIND_MASK = 0x3;
static const int V2_HAS_SELECTOR = 1 << 2;
static const int V2_HAS_RECEIVER = 1 << 3;
static const int V2_MAX_LEB_BYTES = 4;

static bool v2_read_leb(const uint8* bytes, word length, word* at, uint32* result) {
  uint32 value = 0;
  for (int i = 0; i < V2_MAX_LEB_BYTES; i++) {
    if (*at >= length) return false;
    uint8 byte = bytes[(*at)++];
    value |= static_cast<uint32>(byte & 0x7f) << (7 * i);
    if ((byte & 0x80) == 0) {
      if (byte == 0 && i > 0) return false;  // Not in its shortest form.
      *result = value;
      return true;
    }
  }
  return false;
}

static V2MethodTable* v2_fail(const char* message, word detail = -1) {
  if (detail >= 0) {
    fprintf(stderr, "format-2 program rejected: %s (%" PRIdPTR ")\n", message, detail);
  } else {
    fprintf(stderr, "format-2 program rejected: %s\n", message);
  }
  return null;
}

V2MethodTable::~V2MethodTable() {
  if (owned_) free(const_cast<V2Method*>(methods_));
}

// Decodes the method header at [*at] into [*m] and advances [*at] past
// the body. Returns false (printing the reason if [report]) if the header
// is malformed.
static bool v2_decode_method(const uint8* bytes, word length, word* at, V2Method* m, bool report) {
  word start = *at;
  if (start + 2 > length) {
    if (report) v2_fail("truncated method header", start);
    return false;
  }
  uint8 arity = bytes[start];
  uint8 flags = bytes[start + 1];
  if ((flags & ~(V2_KIND_MASK | V2_HAS_SELECTOR | V2_HAS_RECEIVER)) != 0) {
    if (report) v2_fail("bad method header flags", start);
    return false;
  }
  int kind = flags & V2_KIND_MASK;
  *at = start + 2;
  uint32 body = 0;
  uint32 selector = V2_NO_VALUE;
  uint32 recv_start = V2_NO_VALUE;
  uint32 recv_end = V2_NO_VALUE;
  uint32 aux = 0;
  bool ok = v2_read_leb(bytes, length, at, &body);
  if (ok && (flags & V2_HAS_SELECTOR) != 0) {
    ok = v2_read_leb(bytes, length, at, &selector) && selector < V2_NO_VALUE;
  }
  if (ok && (flags & V2_HAS_RECEIVER) != 0) {
    uint32 size = 0;
    ok = v2_read_leb(bytes, length, at, &recv_start) &&
         v2_read_leb(bytes, length, at, &size) &&
         size != 0 && recv_start + size <= V2_NO_VALUE;
    recv_end = recv_start + size;
  }
  if (ok && (kind == V2_KIND_FIELD_ACCESSOR || kind == V2_KIND_LAMBDA)) {
    ok = v2_read_leb(bytes, length, at, &aux) && aux <= 0xffff;
  }
  if (!ok) {
    if (report) v2_fail("bad method header", *at);
    return false;
  }
  word entry = *at;
  word end = entry + body;
  if (end > length) {
    if (report) v2_fail("truncated method body", entry);
    return false;
  }
  // The record holds the length in 16 bits (compiled bodies have at
  // most a few KB).
  if (body > 0xffff) {
    if (report) v2_fail("method body too large", body);
    return false;
  }
  memset(m, 0, sizeof(*m));
  m->entry = entry;
  m->length = body;
  m->selector = selector;
  m->aux = aux;
  m->recv_start = recv_start;
  m->recv_end = recv_end;
  m->arity = arity;
  m->kind = kind;
  *at = end;
  return true;
}

static uint32 v2_read_u32_le(const uint8* p) {
  return static_cast<uint32>(p[0]) | (static_cast<uint32>(p[1]) << 8) |
         (static_cast<uint32>(p[2]) << 16) | (static_cast<uint32>(p[3]) << 24);
}

// The program's method table literal (see TABLE_LITERAL_MARKER), if it is
// exactly the table compute() would build: decodes every header again and
// compares it with the literal's record. Allocates only the table object.
V2MethodTable* V2MethodTable::from_literal(Program* program) {
  // Not yet created (-1) while the compiler builds the program.
  word literals = program->literals.length();
  if (literals <= 0) return null;
  Object* last = program->literals.at(literals - 1);
  if (!is_byte_array(last)) return null;
  ByteArray::Bytes literal(ByteArray::cast(last));
  const uint8* data = literal.address();
  word size = literal.length();
  if (size < TABLE_LITERAL_HEADER_SIZE) return null;
  // The records are read as V2Method (u32 and u16 fields): the bytes must
  // be aligned (program heap and off-heap allocations are word aligned).
  if ((reinterpret_cast<uword>(data) & 3) != 0) return null;
  if (v2_read_u32_le(data) != TABLE_LITERAL_MARKER) return null;
  uword count = v2_read_u32_le(data + 4);
  const uint8* bytes = program->bytecodes.data();
  word length = program->bytecodes.length();
  if (v2_read_u32_le(data + 8) != static_cast<uword>(length)) return null;
  if (count == 0 || count >= 0x1000000) return null;
  if (static_cast<uword>(size - TABLE_LITERAL_HEADER_SIZE) != count * sizeof(V2Method)) return null;
  const V2Method* records = reinterpret_cast<const V2Method*>(data + TABLE_LITERAL_HEADER_SIZE);
  word at = V2_TAG_SIZE;
  uword index = 0;
  while (at < length) {
    V2Method m;
    if (index >= count) return null;
    if (!v2_decode_method(bytes, length, &at, &m, false)) return null;
    if (memcmp(&m, &records[index], sizeof(V2Method)) != 0) return null;
    index++;
  }
  if (index != count) return null;
  return _new V2MethodTable(records, count, false);
}

uint8* V2MethodTable::encode_table_literal(Program* program, word* length) {
  V2MethodTable* table = compute(program);
  if (table == null) return null;
  word count = table->length();
  word size = TABLE_LITERAL_HEADER_SIZE + count * sizeof(V2Method);
  uint8* result = unvoid_cast<uint8*>(malloc(size));
  if (result != null) {
    uint32 header[4] = {
      TABLE_LITERAL_MARKER,
      static_cast<uint32>(count),
      static_cast<uint32>(program->bytecodes.length()),
      0
    };
    // Hosts and devices are little endian (records are copied as is).
    memcpy(result, header, sizeof(header));
    memcpy(result + TABLE_LITERAL_HEADER_SIZE, table->methods(), count * sizeof(V2Method));
    *length = size;
  }
  delete table;
  return result;
}

// Decodes the method headers (format note 15; the reference decoder is
// method_table_v2 in verified/spec/src/interp/loader.rs). Only what is
// needed to build the table is checked here: the tag, the header encoding,
// and that every body lies inside the bytecodes. Everything else (dispatch
// table, receiver ranges, instructions, branch targets, terminators, HALT
// in untrusted programs, the program heap) is the structural verifier's
// job (verifier_v2.h), which runs on this very table before an untrusted
// program runs. Trusted format-2 programs are verified only with
// -Xverify/TOIT_VERIFY: the core checks every stuck state of the
// specification at run time, so an unverified program cannot make it
// access memory outside the tables.
bool V2MethodTable::trusted_on_verified_loop() {
  if (!checked_loop_linked()) return true;
  static int enabled = -1;
  if (enabled < 0) {
    const char* env = getenv("TOIT_TRUSTED_CHECKED_LOOP");
    enabled = (env != null && env[0] != '\0' && env[0] != '0') ? 0 : 1;
  }
  return enabled == 1;
}

V2MethodTable* V2MethodTable::compute(Program* program, bool* out_of_memory) {
  if (out_of_memory != null) *out_of_memory = false;
  const uint8* bytes = program->bytecodes.data();
  word length = program->bytecodes.length();
  if (!program->is_format2()) return v2_fail("missing tag");
  if (length >= V2_MAX_TABLE) return v2_fail("bytecodes too large");
  // The table literal, if the compiler appended one that matches.
  V2MethodTable* in_place = from_literal(program);
  if (in_place != null) return in_place;
  // First pass: count the methods.
  word count = 0;
  for (int pass = 0; pass < 2; pass++) {
    V2Method* methods = null;
    if (pass == 1) {
      if (count == 0 || count >= 0x1000000) return v2_fail("bad method count", count);
      methods = unvoid_cast<V2Method*>(calloc(count, sizeof(V2Method)));
      if (methods == null) {
        if (out_of_memory != null) *out_of_memory = true;
        return null;
      }
    }
    word at = V2_TAG_SIZE;
    word index = 0;
    while (at < length) {
      V2Method m;
      if (!v2_decode_method(bytes, length, &at, &m, true)) {
        free(methods);
        return null;
      }
      if (pass == 1) methods[index] = m;
      index++;
    }
    if (pass == 0) {
      count = index;
      continue;
    }
    V2MethodTable* table = _new V2MethodTable(methods, count, true);
    if (table == null) {
      free(methods);
      if (out_of_memory != null) *out_of_memory = true;
    }
    return table;
  }
  UNREACHABLE();
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
    word e = methods_[mid].entry;
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
