// Copyright (C) 2026 Toit contributors.

// Included inside namespace toit by the VM and its call-contract harness.
struct V2TableLiteral {
  const uint8* records;
  uword count;
};

enum class V2LiteralStatus { OK, NO_TABLE, OTHER_BYTECODES, BAD_COUNT, BAD_SIZE };
static ByteArray* v2_last_table_literal(Program* program);
static V2LiteralStatus v2_read_table_literal(const uint8* data, word size, word length, V2TableLiteral* table);
static const char* v2_validate_records(const uint8* bytes, word length, const uint8* records,
                                       uword count, word* detail);

static V2MethodTable* v2_fail(const char* message, word detail = -1) {
  if (detail >= 0) {
    fprintf(stderr, "format-2 program rejected: %s (%" PRIdPTR ")\n", message, detail);
  } else {
    fprintf(stderr, "format-2 program rejected: %s\n", message);
  }
  return null;
}

// The table literal (format note 21), checked: every header lies inside
// the bytecodes before its entry (the core reads headers without bounds
// checks: `table_ok` in verified/spec/src/v2/vprog.rs, part of the
// loader's contract `prog_rel`), every entry but a block's is odd and the
// bytecodes are 2-byte aligned (aligned u16 loads), the methods follow
// each other from the tag to the end of the bytecodes with nonempty
// bodies, and every header
// is in its canonical form (no unknown kind-byte bits, SINGLE only for a
// method, a range of at least two classes in the long form, no empty
// accessor range). Only what
// is needed for the table: everything else (dispatch table, receiver
// ranges, instructions, branch targets, terminators, HALT in untrusted
// programs, the program heap) is the structural verifier's job
// (verifier_v2.h), which runs on this very table before an untrusted
// program runs. Trusted format-2 programs are verified only with
// -Xverify/TOIT_VERIFY: the core checks every stuck state of the
// specification at run time, so an unverified program cannot make it
// access memory outside the tables.
V2MethodTable* V2MethodTable::compute(Program* program, bool* out_of_memory) {
  if (out_of_memory != null) *out_of_memory = false;
  const uint8* bytes = program->bytecodes.data();
  word length = program->bytecodes.length();
  if (!program->is_format2()) return v2_fail("missing tag");
  if (length >= V2_MAX_BYTECODES) return v2_fail("bytecodes too large");
  // 2-byte aligned bytecodes (program heap and off-heap allocations are
  // word aligned): with the odd entries, every u16 header field is aligned
  // (`prog_rel` in verified/core/src/abs.rs).
  if ((reinterpret_cast<uword>(bytes) & 1) != 0) return v2_fail("unaligned bytecodes");
  ByteArray* last = v2_last_table_literal(program);
  if (last == null) return v2_fail("no method table");
  ByteArray::Bytes literal(last);
  V2TableLiteral table;
  switch (v2_read_table_literal(literal.address(), literal.length(), length, &table)) {
    case V2LiteralStatus::NO_TABLE: return v2_fail("no method table");
    case V2LiteralStatus::OTHER_BYTECODES: return v2_fail("method table of other bytecodes");
    case V2LiteralStatus::BAD_COUNT: return v2_fail("bad method count", table.count);
    case V2LiteralStatus::BAD_SIZE: return v2_fail("bad method table size", literal.length());
    case V2LiteralStatus::OK: break;
  }
  word detail;
  const char* error = v2_validate_records(bytes, length, table.records, table.count, &detail);
  if (error != null) return v2_fail(error, detail);
  return install(table.records, table.count, bytes, length, out_of_memory);
}
