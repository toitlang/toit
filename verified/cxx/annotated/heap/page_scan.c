// Copyright (C) 2026 Toit contributors.
#include <stdint.h>
#include <stdbool.h>
typedef uint32_t uint32;
typedef uint8_t uint8;
typedef uintptr_t uword;
typedef intptr_t word;
typedef uint64_t uint64;
#include "../../../../src/heap_page_scan.h"
#include "../../../../src/third_party/dartino/sweep_empty_cards.h"

// Observe one arbitrary card across repeated production steps. The intervening
// sweep actions preserve the mark map until the chunk has been processed.
/*@ requires witness < cards;
    requires \valid_read(marks + (0 .. cards-1)) && \valid(starts + (0 .. cards-1));
    requires \separated(marks + (0 .. cards-1), starts + (0 .. cards-1));
    terminates \true;
    assigns starts[0 .. cards-1];
    ensures \result == (marks[witness] != 0 ? 1 : 0);
*/
unsigned sweep_marked_visits(const uint32* marks, uint8* starts, uword cards, uword witness) {
  unsigned visits = 0;
  uword card = 0;
  /*@ loop invariant card <= cards;
      loop invariant card == 0 || card == cards || marks[card-1] != 0;
      loop invariant visits == (witness < card && marks[witness] != 0 ? 1 : 0);
      loop assigns card, visits, starts[0 .. cards-1];
      loop variant cards-card;
  */
  while (card < cards) {
    SweepCardStep step = sweep_card_step(marks, starts, cards, card, 2);
    if (step.marked_card == witness) visits++;
    card = step.next_card;
  }
  return visits;
}

#include "../../../../src/third_party/dartino/overflow_registration.h"

typedef struct {
  uint8 card;
  uint8 offset;
} DeferredStart;

/*@ requires witness < 8;
    requires \valid(bits) && \valid(starts + (0 .. 7));
    requires \valid_read(events + (0 .. count-1));
    requires \separated(bits, starts + (0 .. 7), events + (0 .. count-1));
    requires \forall integer k; 0 <= k < count ==> events[k].card < 8 && events[k].offset != empty;
    terminates \true;
    assigns *bits, starts[0 .. 7];
    ensures ((*bits >> witness) & 1) != 0 <==> ((\old(*bits) >> witness) & 1) != 0 ||
                  (\exists integer k; 0 <= k < count && events[k].card == witness);
    ensures \forall integer k; 0 <= k < count && events[k].card == witness ==>
                  starts[witness] != empty && starts[witness] <= events[k].offset;
    ensures \old(starts[witness]) != empty ==> starts[witness] != empty && starts[witness] <= \old(starts[witness]);
    ensures starts[witness] == \old(starts[witness]) ||
                  (\exists integer k; 0 <= k < count && events[k].card == witness && starts[witness] == events[k].offset);
*/
void record_overflow_sequence(uint8* bits, uint8* starts, const DeferredStart* events, uword count,
                              unsigned witness, uint8 empty) {
  //@ ghost uword last = count;
  //@ ghost uword minimum = count;
  /*@ loop invariant i <= count;
      loop invariant last == count || (last < i && events[last].card == witness);
      loop invariant minimum == count ? starts[witness] == \at(starts[witness],Pre) :
                minimum < i && events[minimum].card == witness && starts[witness] == events[minimum].offset;
      loop invariant ((*bits >> witness) & 1) != 0 <==> ((\at(*bits,Pre) >> witness) & 1) != 0 || last != count;
      loop invariant \forall integer k; 0 <= k < i && events[k].card == witness ==> last != count;
      loop invariant \forall integer k; 0 <= k < i && events[k].card == witness ==>
                  starts[witness] != empty && starts[witness] <= events[k].offset;
      loop invariant \at(starts[witness],Pre) != empty ==> starts[witness] != empty && starts[witness] <= \at(starts[witness],Pre);
      loop assigns i, last, minimum, *bits, starts[0 .. 7];
      loop variant count-i;
  */
  for (uword i = 0; i < count; i++) {
    unsigned card = events[i].card;
    /*@ ghost if (card == witness) {
          last = i;
          if (starts[witness] == empty || events[i].offset < starts[witness]) minimum = i;
        } @*/
    //@ ghost uint8 previous = starts[witness];
    record_overflow_start(bits, starts + card, card, events[i].offset, empty);
    //@ assert previous != empty ==> starts[witness] != empty && starts[witness] <= previous;
    //@ assert card == witness ==> starts[witness] != empty && starts[witness] <= events[i].offset;
    //@ assert \forall integer k; 0 <= k < i && events[k].card == witness ==> starts[witness] != empty && starts[witness] <= events[k].offset;
  }
}
