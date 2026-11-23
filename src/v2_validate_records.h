// Copyright (C) 2026 Toit contributors.

// Internal format-2 validation loop shared by the VM and its WP proof.

enum V2Header { V2_HEADER_OK, V2_HEADER_BAD_ENTRY, V2_HEADER_BAD_KIND, V2_HEADER_BAD_POSITION, V2_HEADER_BAD_RANGE };
enum V2NextHeader { V2_NEXT_OK, V2_NEXT_BAD_ENTRY, V2_NEXT_EMPTY_BODY };

/*@ requires \valid_read(p+(0..3));
    terminates \true;
    assigns \nothing;
    exits \false;
    ensures 0 <= \result < 16777216 && \result == record_bci(p);
*/
static word v2_record_entry(const uint8* p);

/*@ requires \valid_read(b+(0..length-1)) && 4 <= expected <= length < 16777216;
    requires 0 <= e < 16777216;
    terminates \true;
    assigns \nothing;
    exits \false;
    ensures V2_HEADER_OK <= \result <= V2_HEADER_BAD_RANGE;
    ensures (\result == V2_HEADER_OK) <==> expected < e < length &&
            canonical(b,e) && header_start(b,e) == expected;
*/
static enum V2Header v2_check_header(const uint8* b, word length, word e, word expected);

/*@ requires \valid_read(b+(0..length-1)) && 4 < e < length < 16777216;
    requires \valid_read(p+(0..3)) && \valid(out);
    requires \separated(out,p+(0..3)) && \separated(out,b+(0..length-1));
    terminates \true;
    assigns *out;
    exits \false;
    ensures V2_NEXT_OK <= \result <= V2_NEXT_EMPTY_BODY;
    ensures \result == V2_NEXT_OK ==> e < *out <= length;
    ensures e < record_bci(p) < length && canonical(b,record_bci(p)) &&
            e < header_start(b,record_bci(p)) ==>
            \result == V2_NEXT_OK && *out == header_start(b,record_bci(p));
*/
static enum V2NextHeader v2_next_header(const uint8* b, word length, word e, const uint8* p, word* out);

/*@ requires \valid(detail);
    assigns *detail;
    ensures \result == message && *detail == value;
*/
static const char* v2_record_error(word* detail, word value, const char* message) {
  *detail = value;
  return message;
}

/*@ requires 4 <= length < 16777216 && 0 < count < 16777216;
    requires \valid_read(bytes+(0..length-1)) && \valid_read(records+(0..4*count-1));
    requires \valid(detail) && \separated(detail,bytes+(0..length-1)) &&
             \separated(detail,records+(0..4*count-1));
    assigns *detail;
    ensures (\result == 0) <==> well_formed{Pre}(bytes,length,records,count);
*/
static const char* v2_validate_records(const uint8* bytes, word length, const uint8* records,
                                      uword count, word* detail) {
  word expected = V2_TAG_SIZE;  // The next header.
  /*@ loop invariant 0 <= i <= count && 4 <= expected <= length;
      loop invariant i == 0 ==> expected == 4;
      loop invariant i > 0 ==> method_entry(records,i-1) < expected;
      loop invariant well_formed(bytes,length,records,count) && i < count ==>
                     expected == header_start(bytes,method_entry(records,i));
      loop invariant \forall integer j; 0 <= j < i ==>
        4 <= header_start(bytes,method_entry(records,j)) < method_entry(records,j) < length &&
        canonical(bytes,method_entry(records,j)) &&
        (j == 0 ? header_start(bytes,method_entry(records,j)) == 4 :
                  method_entry(records,j-1) < header_start(bytes,method_entry(records,j)));
      loop assigns i, expected;
      loop variant count-i;
  */
  for (uword i = 0; i < count; i++) {
    word entry = v2_record_entry(records + 4 * i);
    //@ assert 0 <= entry < 16777216 && entry == method_entry(records,i);
    switch (v2_check_header(bytes, length, entry, expected)) {
      case V2_HEADER_BAD_ENTRY: return v2_record_error(detail, i, "bad method entry");
      case V2_HEADER_BAD_KIND: return v2_record_error(detail, entry - 1, "bad method kind byte");
      case V2_HEADER_BAD_POSITION: return v2_record_error(detail, i, "methods do not follow each other");
      case V2_HEADER_BAD_RANGE: return v2_record_error(detail, entry, "bad receiver range");
      case V2_HEADER_OK: break;
    }
    //@ assert expected == header_start(bytes,entry) && canonical(bytes,entry) && expected < entry < length;
    // The body is at least one instruction; the next header follows it.
    expected = entry + 1;
    if (i + 1 < count) {
      switch (v2_next_header(bytes, length, entry, records + 4 * (i + 1), &expected)) {
        case V2_NEXT_BAD_ENTRY: return v2_record_error(detail, i + 1, "bad method entry");
        case V2_NEXT_EMPTY_BODY: return v2_record_error(detail, i, "empty method body");
        case V2_NEXT_OK: break;
      }
    }
    //@ assert method_entry(records,i) < expected <= length;
  }
  if (expected > length) return v2_record_error(detail, -1, "truncated method body");
  return 0;
}
