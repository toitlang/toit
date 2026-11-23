// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#include <type_traits>
#define private public
#define protected public
#include "third_party/dartino/object_memory.h"
#undef protected
#undef private

using namespace toit;

// Chunks participating in the native list operations checked below.
extern Chunk current_chunk;
extern Chunk following_chunk;
extern Chunk appended_chunk;

// Only the endpoints are needed to append. Distinct first and last chunks
// may enclose any number of untouched chunks.
static void check_append_and_unlink() {
  ChunkList list;
  auto anchor = &list.anchor_;
  CXXV_ASSERT(list.is_empty() && anchor->next_ == anchor && anchor->prev_ == anchor,
              "a fresh list is circular and empty");
  bool empty = nondet_bool();
  auto first = empty ? anchor : static_cast<ChunkList::Element*>(&current_chunk);
  auto last = first;
  if (!empty && nondet_bool()) last = static_cast<ChunkList::Element*>(&following_chunk);
  anchor->next_ = first;
  anchor->prev_ = last;
  first->prev_ = anchor;
  last->next_ = anchor;
  auto added = static_cast<ChunkList::Element*>(&appended_chunk);
  added->next_ = added->prev_ = added;
  auto lo = appended_chunk.start();
  auto hi = appended_chunk.end();

  auto cursor = list.begin();
  auto end = list.end();
  static_assert(std::is_same<decltype(cursor), ChunkList::Iterator>::value, "mutable begin cursor");
  static_assert(std::is_trivially_copy_constructible<ChunkList::Iterator>::value &&
                std::is_trivially_destructible<ChunkList::Iterator>::value, "mutable cursor lifetime");
  CXXV_ASSERT(end.entry_ == anchor && (cursor != end) == !empty, "the mutable range ends at its anchor");
  if (!empty) CXXV_ASSERT(*cursor == &current_chunk, "mutable dereference returns the first chunk");
  ChunkList::Iterator tail(last);
  list.append(&appended_chunk);
  auto after_tail = tail;
  ++after_tail;
  CXXV_ASSERT(after_tail != end && *after_tail == &appended_chunk && tail.entry_ == last,
              "a cursor advanced after append observes the new link and leaves its copy intact");
  ++after_tail;
  CXXV_ASSERT(!(after_tail != end), "the appended chunk leads to the original end cursor");
  CXXV_ASSERT(anchor->next_ == (empty ? added : first) && anchor->prev_ == added,
              "append retains the head and installs the new tail");
  CXXV_ASSERT(last->next_ == added && added->prev_ == last && added->next_ == anchor,
              "append reconnects both neighbors");
  CXXV_ASSERT(appended_chunk.start() == lo && appended_chunk.end() == hi,
              "linking preserves the chunk bounds");

  list.unlink(added);
  CXXV_ASSERT(anchor->next_ == first && anchor->prev_ == last &&
              first->prev_ == anchor && last->next_ == anchor, "unlink restores the endpoints");
  CXXV_ASSERT(added->next_ == added && added->prev_ == added, "removed chunk is detached");
}

// Head removal touches the anchor, the current head and its successor.
static void check_unlink_first() {
  ChunkList list;
  auto anchor = &list.anchor_;
  CXXV_ASSERT(list.first() == nullptr, "an empty space has no chunk to retire");
  auto head = static_cast<ChunkList::Element*>(&current_chunk);
  auto next = nondet_bool() ? anchor : static_cast<ChunkList::Element*>(&following_chunk);
  auto last = next == anchor ? head : (nondet_bool() ? next : static_cast<ChunkList::Element*>(&appended_chunk));
  anchor->next_ = head;
  anchor->prev_ = last;
  head->prev_ = anchor;
  head->next_ = next;
  next->prev_ = head;
  last->next_ = anchor;
  auto next_link = next->next_;
  Chunk* selected = list.first();
  CXXV_ASSERT(selected == &current_chunk, "select the current head for teardown");
  list.unlink(selected);
  CXXV_ASSERT(head->prev_ == head && head->next_ == head, "detach both links before retiring the head");
  CXXV_ASSERT(anchor->next_ == next && next->prev_ == anchor, "reconnect the successor to the anchor");
  if (next == anchor) {
    CXXV_ASSERT(list.first() == nullptr && list.last() == nullptr, "retiring the last head empties the list");
  } else {
    CXXV_ASSERT(list.first() == &following_chunk && anchor->prev_ == last && last->next_ == anchor &&
                next->next_ == next_link, "the successor becomes the head and the remaining links survive");
  }
}

int main() {
  check_append_and_unlink();
  check_unlink_first();
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  static_assert(std::is_trivially_copy_constructible<ChunkList::ConstIterator>::value, "cursor copy");
  static_assert(std::is_trivially_destructible<ChunkList::ConstIterator>::value, "cursor destruction");
  ChunkList list;
  const ChunkList& chunks = list;
  bool empty = nondet_bool();
  bool last = nondet_bool();
  list.anchor_.next_ = empty ? &list.anchor_ : static_cast<ChunkList::Element*>(&current_chunk);
  current_chunk.next_ = last ? &list.anchor_ : static_cast<ChunkList::Element*>(&following_chunk);
  auto it = chunks.begin();
  auto end = chunks.end();
  static_assert(std::is_same<decltype(it), ChunkList::ConstIterator>::value, "begin cursor type");
  static_assert(std::is_same<decltype(end), ChunkList::ConstIterator>::value, "end cursor type");
  CXXV_ASSERT(end.entry_ == &list.anchor_, "end is the anchor of this list");
  CXXV_ASSERT((it != end) == !empty, "an empty list stops before dereference");
  if (!empty) {
    CXXV_ASSERT(*it == &current_chunk, "dereference recovers the enclosing chunk");
    auto next = it;
    ++next;
    CXXV_ASSERT(*it == &current_chunk, "advancing a copied cursor leaves the original unchanged");
    CXXV_ASSERT((next != end) == !last, "increment stops exactly at the anchor");
    if (!last) CXXV_ASSERT(*next == &following_chunk, "increment follows the current forward link");
  }
}
