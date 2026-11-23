// Copyright (C) 2026 Toit contributors.

#pragma once

/*@ requires \valid(bits) && \valid(start) && \separated(bits, start);
    requires card < 8 && offset != empty;
    assigns *bits, *start;
    ensures *bits == (\old(*bits) | (1 << card));
    ensures ((*bits >> card) & 1) == 1;
    ensures \forall integer j; 0 <= j < 8 && j != card ==> ((*bits >> j) & 1) == ((\old(*bits) >> j) & 1);
    ensures *start != empty && *start <= offset;
    ensures \old(*start) != empty ==> *start <= \old(*start);
    ensures *start == (\old(*start) == empty || offset < \old(*start) ? offset : \old(*start));
*/
static inline void record_overflow_start(uint8* bits, uint8* start, unsigned card, uint8 offset, uint8 empty) {
  *bits |= 1U << card;
  if (*start == empty || offset < *start) *start = offset;
}
