// Copyright (C) 2026 Toit contributors.

#ifndef TOIT_VERIFIED_CHUNK_CHAIN_H
#define TOIT_VERIFIED_CHUNK_CHAIN_H

#include <stdint.h>
typedef struct Chunk { struct Chunk *next_; uintptr_t start_; uintptr_t end_; } Chunk;
typedef struct ChunkList { Chunk anchor_; } ChunkList;

/*@
predicate chunk_node(Chunk *p, Chunk *anchor; Chunk *next, int bytes) =
  (uintptr_t)p != (uintptr_t)anchor &*& p != anchor &*& p->next_ |-> next &*& p->start_ |-> ?lo &*& p->end_ |-> ?hi &*& lo <= hi &*& bytes == hi - lo;

predicate chunk_chain(Chunk *p, Chunk *anchor; list<Chunk *> nodes, int bytes) =
  p == anchor ? nodes == nil &*& bytes == 0 :
    chunk_node(p, anchor, ?next, ?size) &*& chunk_chain(next, anchor, ?tail, ?remaining) &*&
    0 <= remaining &*& nodes == cons(p, tail) &*& bytes == size + remaining;

predicate visited(list<Chunk *> reverse_order, Chunk *first, Chunk *anchor, Chunk *cursor; int bytes) =
  switch (reverse_order) {
    case nil: return cursor == first &*& bytes == 0;
    case cons(last, rest): return chunk_node(last, anchor, ?next, ?size) &*& next == cursor &*&
      visited(rest, first, anchor, last, ?previous) &*& bytes == previous + size;
  };

fixpoint list<Chunk *> restored(list<Chunk *> prefix,list<Chunk *> tail) {
  switch(prefix) {
    case nil: return tail;
    case cons(h,r): return restored(r,cons(h,tail));
  }
}
lemma void restore_chain(real f, list<Chunk *> done, Chunk *first, Chunk *anchor, Chunk *cursor)
  requires [f]visited(done, first, anchor, cursor, ?prefix) &*& [f]chunk_chain(cursor, anchor, ?tail, ?rest) &*& 0 <= rest;
  ensures [f]chunk_chain(first, anchor, restored(done,tail), prefix + rest);
{
  open [f]visited(done, first, anchor, cursor, prefix);
  switch (done) {
    case nil:
    case cons(last, previous):
      open [f]chunk_node(last, anchor, cursor, ?size);
      close [f]chunk_node(last, anchor, cursor, size);
      close [f]chunk_chain(last, anchor, cons(last, tail), size + rest);
      restore_chain(f, previous, first, anchor, last);
  }
}
@*/

#endif
