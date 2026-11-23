// Copyright (C) 2026 Toit contributors.

#pragma once

typedef struct {
  uword next;
  bool whole_chunk;
} EmptyCardRun;

/*@ requires first < cards;
    requires \valid_read(marks + (0 .. cards-1)) && \valid(starts + (0 .. cards-1));
    requires \separated(marks + (0 .. cards-1), starts + (0 .. cards-1));
    terminates \true;
    assigns starts[first .. cards-1];
    ensures first <= \result.next <= cards;
    ensures \forall integer i; first <= i < \result.next ==> marks[i] == 0 && starts[i] == empty_start;
    ensures \result.next == cards || marks[\result.next] != 0;
    ensures marks[first] == 0 ==> first < \result.next;
    ensures \forall integer i; \result.next <= i < cards ==> starts[i] == \old(starts[i]);
    ensures \result.whole_chunk <==> (first == 0 && (\forall integer i; 0 <= i < cards ==> marks[i] == 0));
*/
static inline EmptyCardRun sweep_empty_cards(const uint32* marks, uint8* starts, uword cards, uword first, uint8 empty_start) {
  uword i = first;
  /*@ loop invariant first <= i <= cards;
      loop invariant \forall integer k; first <= k < i ==> marks[k] == 0 && starts[k] == empty_start;
      loop invariant \forall integer k; i <= k < cards ==> starts[k] == \at(starts[k],Pre);
      loop assigns i, starts[first .. cards-1];
      loop variant cards-i;
  */
  while (i < cards && marks[i] == 0) {
    starts[i] = empty_start;
    i++;
  }
  EmptyCardRun result = {i, first == 0 && i == cards};
  return result;
}

typedef struct {
  uword marked_card;  // First nonempty card at or after first, or cards.
  uword next_card;    // First card to examine on the next iteration.
  uint32 preceding_marks;
  uint32 marks;
  bool whole_chunk;
} SweepCardStep;

/*@ requires first < cards;
    requires first == 0 || marks[first-1] != 0;
    requires \valid_read(marks + (0 .. cards-1)) && \valid(starts + (0 .. cards-1));
    requires \separated(marks + (0 .. cards-1), starts + (0 .. cards-1));
    assigns starts[first .. cards-1];
    ensures first <= \result.marked_card <= cards;
    ensures first < \result.next_card <= cards;
    ensures \result.next_card == (\result.marked_card == cards ? cards : \result.marked_card+1);
    ensures \result.next_card == cards || marks[\result.next_card-1] != 0;
    ensures \result.marks == (\result.marked_card == cards ? 0 : marks[\result.marked_card]);
    ensures \result.marks == 0 <==> \result.marked_card == cards;
    ensures \forall integer k; first <= k < \result.marked_card ==> marks[k] == 0 && starts[k] == empty_start;
    ensures \result.marked_card > first ==> \result.preceding_marks == (first == 0 ? 4294967295 : marks[first-1]) && \result.preceding_marks != 0;
    ensures \forall integer k; \result.marked_card <= k < cards ==> starts[k] == \old(starts[k]);
    ensures \result.whole_chunk <==> (first == 0 && (\forall integer k; 0 <= k < cards ==> marks[k] == 0));
*/
static inline SweepCardStep sweep_card_step(const uint32* marks, uint8* starts, uword cards, uword first, uint8 empty_start) {
  uint32 bits = marks[first];
  if (bits != 0) {
    SweepCardStep step = {first, first + 1, 0, bits, false};
    return step;
  }
  EmptyCardRun run = sweep_empty_cards(marks, starts, cards, first, empty_start);
  uint32 previous = first == 0 ? UINT32_MAX : marks[first-1];
  bool at_end = run.next == cards;
  SweepCardStep step = {run.next, at_end ? cards : run.next + 1, previous,
                        at_end ? 0U : marks[run.next], run.whole_chunk};
  return step;
}

/*@ requires first <= 32;
    requires \valid(words + (0 .. 31));
    terminates \true;
    assigns words[0 .. 31];
    ensures \forall integer k; first <= k < 32 && ((marks >> k) & 1) == 0 ==> words[k] == filler;
    ensures \forall integer k; 0 <= k < 32 && (k < first || ((marks >> k) & 1) != 0) ==> words[k] == \old(words[k]);
*/
static inline void fill_unmarked_words(word* words, uint32 marks, unsigned first, word filler) {
  /*@ loop invariant first <= i <= 32;
      loop invariant \forall integer k; first <= k < i && ((marks >> k) & 1) == 0 ==> words[k] == filler;
      loop invariant \forall integer k; 0 <= k < first ==> words[k] == \at(words[k],Pre);
      loop invariant \forall integer k; i <= k < 32 ==> words[k] == \at(words[k],Pre);
      loop invariant \forall integer k; first <= k < i && ((marks >> k) & 1) != 0 ==> words[k] == \at(words[k],Pre);
      loop assigns i, words[0 .. 31];
      loop variant 32-i;
  */
  for (unsigned i = first; i < 32; i++) {
    if (((marks >> i) & 1U) == 0) words[i] = filler;
  }
}
