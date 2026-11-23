// Copyright (C) 2026 Toit contributors.

// Format-2 record semantics used by the shared validation loop.
#include <stdint.h>
typedef intptr_t word;
typedef uintptr_t uword;
typedef uint8_t uint8;
enum { V2_TAG_SIZE = 4, V2_RECORD_ENTRY_SHIFT = 8 };

/*@ logic integer record_bci{L}(uint8* p) = p[1] + 256*p[2] + 65536*p[3];
    logic integer method_entry{L}(uint8* records, integer i) = record_bci(records + 4*i);
    logic integer header_width(integer kind) =
      kind == 4 ? 5 : kind == 0 ? 7 : kind == 1 ? 9 : kind == 2 ? 3 : 1;
    logic integer header_start{L}(uint8* b, integer e) =
      e - header_width(b[e-1]);
    logic integer u16le{L}(uint8* p) = p[0] + 256*p[1];
    predicate canonical{L}(uint8* b, integer e) =
      0 <= b[e-1] <= 4 &&
      (b[e-1] != 3 ==> e % 2 == 1) &&
      (b[e-1] == 0 ==> u16le(b+e-7) >= u16le(b+e-5) + 2) &&
      (b[e-1] == 1 ==> u16le(b+e-5) < u16le(b+e-7) ||
                        (u16le(b+e-5) == 65535 && u16le(b+e-7) == 65535));
    predicate well_formed{L}(uint8* b, integer length, uint8* r, integer count) =
      \forall integer j; 0 <= j < count ==>
        4 <= header_start(b,method_entry(r,j)) < method_entry(r,j) < length &&
        canonical(b,method_entry(r,j)) &&
        (j == 0 ? header_start(b,method_entry(r,j)) == 4 :
                  method_entry(r,j-1) < header_start(b,method_entry(r,j)));
*/

#include "../../../../src/v2_validate_records.h"
