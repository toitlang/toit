// Copyright (C) 2026 Toit contributors.

#pragma once
// The host page allocator holds its resource mutex throughout this scan.
/*@ predicate free_page_run(integer bits, integer pages, integer start) =
      0 <= start <= 64 - pages &&
      ((bits >> start) & ((1 << pages) - 1)) == 0;
*/

/*@ requires 1 <= pages <= 64;
    terminates \true;
    exits \false;
    assigns \nothing;
    ensures \result == 64 || free_page_run(bits, pages, \result);
    ensures \forall integer j; free_page_run(bits, pages, j) ==> \result <= j;
*/
static unsigned free_page_offset(uint64 bits, unsigned pages);

/*@ requires 1 <= pages <= 64;
    requires words <= UINTPTR_MAX / 64;
    requires \valid_read(bitmap + (0 .. words-1));
    terminates \true;
    exits \false;
    assigns \nothing;
    ensures \result <= words * 64;
    ensures \result < words * 64 ==>
      free_page_run(bitmap[\result / 64], pages, \result % 64);
    ensures \forall integer i, j; 0 <= i < words && free_page_run(bitmap[i], pages, j) ==>
      \result <= 64 * i + j;
*/
static uword first_free_page(const uint64* bitmap, uword words, unsigned pages) {
  /*@ loop invariant 0 <= i <= words;
      loop invariant \forall integer k, j; 0 <= k < i ==> !free_page_run(bitmap[k], pages, j);
      loop assigns i;
      loop variant words - i;
  */
  for (uword i = 0; i < words; i++) {
    unsigned offset = free_page_offset(bitmap[i], pages);
    if (offset < 64) return 64 * i + offset;
  }
  return 64 * words;
}

/*@ logic integer page_run_bits(integer pages, integer start) =
      (uint64)((18446744073709551615 >> (64 - pages)) << start);
*/

/*@ requires 1 <= pages <= 64 && start <= 64 - pages;
    assigns \nothing;
    ensures \result == page_run_bits(pages, start);
*/
static uint64 page_run_mask(unsigned pages, unsigned start) {
  return (UINT64_MAX >> (64 - pages)) << start;
}

/*@ requires 1 <= pages <= 64 && page % 64 <= 64 - pages;
    requires \valid(bitmap + page / 64);
    assigns bitmap[page / 64];
    ensures bitmap[page / 64] == (\old(bitmap[page / 64]) |
              page_run_bits(pages, page % 64));
*/
static void claim_page_run(uint64* bitmap, uword page, unsigned pages) {
  bitmap[page / 64] |= page_run_mask(pages, page % 64);
}

/*@ requires 1 <= pages <= 64 && page % 64 <= 64 - pages;
    requires \valid(bitmap + page / 64);
    assigns bitmap[page / 64];
    ensures bitmap[page / 64] == (\old(bitmap[page / 64]) &
              (uint64)~page_run_bits(pages, page % 64));
*/
static void release_page_run(uint64* bitmap, uword page, unsigned pages) {
  bitmap[page / 64] &= ~page_run_mask(pages, page % 64);
}
