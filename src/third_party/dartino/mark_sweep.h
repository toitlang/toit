// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#pragma once

#include "gc_metadata.h"
#include "../../utils.h"
#include "../../objects.h"
#include "../../program.h"
#include "../../process.h"

namespace toit {

class MarkingStack {
 public:
  MarkingStack() : next_(&backing_[0]), limit_(&backing_[CHUNK_SIZE]) {}

  void push(HeapObject* object) {
    ASSERT(GcMetadata::is_marked(object));
    if (next_ < limit_) {
      *(next_++) = object;
    } else {
      overflowed_ = true;
      GcMetadata::mark_stack_overflow(object);
    }
  }

  bool is_empty() { return next_ == &backing_[0]; }
  bool is_overflowed() { return overflowed_; }
  void clear_overflow() { overflowed_ = false; }

  void empty(RootCallback* visitor);
  void process(RootCallback* visitor, Space* old_space, Space* new_space);

 private:
  static const int CHUNK_SIZE = 128;
  HeapObject** next_;
  HeapObject** limit_;
  HeapObject* backing_[CHUNK_SIZE];
  bool overflowed_ = false;
};

class MarkingVisitor : public RootCallback {
 public:
  MarkingVisitor(SemiSpace* new_space, MarkingStack* marking_stack)
      : new_space_address_(new_space->single_chunk_start()),
        new_space_size_(new_space->size()),
        marking_stack_(marking_stack) {}

  virtual void visit_class(Object** p) {}

  virtual void visit_block(Object** start, Object** end) {
    // Mark live all HeapObjects pointed to by pointers in [start, end)
    for (Object** p = start; p < end; p++) mark_pointer(*p);
  }

 private:
  void INLINE mark_pointer(Object* object) {
    if (!GcMetadata::in_new_or_old_space(object)) return;
    HeapObject* heap_object = HeapObject::cast(object);
    if (!GcMetadata::mark_grey_if_not_marked(heap_object)) {
      marking_stack_->push(heap_object);
    }
  }

  uword new_space_address_;
  uword new_space_size_;
  MarkingStack* marking_stack_;
};

class FreeList {
 public:
#if defined(_MSC_VER)
  // Work around Visual Studo 2013 bug 802058
  FreeList(void) {
    memset(buckets_, 0, NUMBER_OF_BUCKETS * sizeof(FreeListRegion*));
  }
#endif

  void add_region(uword free_start, uword free_size) {
    FreeListRegion* result = FreeListRegion::create_at(free_start, free_size);
    if (!result) {
      // Since the region was too small to be turned into an actual
      // free list region it was just filled with one-word fillers.
      // It can be coalesced with other free regions later.
      return;
    }
    const int WORD_BITS = sizeof(uword) * BYTE_BIT_SIZE;
    int bucket = WORD_BITS - Utils::clz(free_size);
    if (bucket >= NUMBER_OF_BUCKETS) bucket = NUMBER_OF_BUCKETS - 1;
    result->set_next_region(buckets_[bucket]);
    buckets_[bucket] = result;
  }

  FreeListRegion* get_region(uword min_size) {
    const int WORD_BITS = sizeof(uword) * BYTE_BIT_SIZE;
    int smallest_bucket = WORD_BITS - Utils::clz(min_size);
    ASSERT(smallest_bucket > 0);

    // Take the first region in the largest list guaranteed to satisfy the
    // allocation.
    for (int i = NUMBER_OF_BUCKETS - 1; i >= smallest_bucket; i--) {
      FreeListRegion* result = buckets_[i];
      if (result != null) {
        ASSERT(result->size() >= min_size);
        FreeListRegion* next_region =
            reinterpret_cast<FreeListRegion*>(result->next_region());
        result->set_next_region(null);
        buckets_[i] = next_region;
        return result;
      }
    }

    // Search the bucket containing regions that could, but are not
    // guaranteed to, satisfy the allocation.
    if (smallest_bucket > NUMBER_OF_BUCKETS) smallest_bucket = NUMBER_OF_BUCKETS;
    FreeListRegion* previous = null;
    FreeListRegion* current = buckets_[smallest_bucket - 1];
    while (current != null) {
      if (current->size() >= min_size) {
        if (previous != null) {
          previous->set_next_region(current->next_region());
        } else {
          buckets_[smallest_bucket - 1] =
              reinterpret_cast<FreeListRegion*>(current->next_region());
        }
        current->set_next_region(null);
        return current;
      }
      previous = current;
      current = reinterpret_cast<FreeListRegion*>(current->next_region());
    }

    return null;
  }

  void clear() {
    for (int i = 0; i < NUMBER_OF_BUCKETS; i++) {
      buckets_[i] = null;
    }
  }

  void merge(FreeList* other) {
    for (int i = 0; i < NUMBER_OF_BUCKETS; i++) {
      FreeListRegion* region = other->buckets_[i];
      if (region != null) {
        FreeListRegion* last_region = region;
        while (last_region->next_region() != null) {
          last_region = FreeListRegion::cast(last_region->next_region());
        }
        last_region->set_next_region(buckets_[i]);
        buckets_[i] = region;
      }
    }
  }

 private:
  // Buckets of power of two sized free lists regions. Bucket i
  // contains regions of size larger than 2 ** (i + 1).
  static const int NUMBER_OF_BUCKETS = 12;
#if defined(_MSC_VER)
  // Work around Visual Studo 2013 bug 802058
  FreeListRegion* buckets_[NUMBER_OF_BUCKETS];
#else
  FreeListRegion* buckets_[NUMBER_OF_BUCKETS] = {null};
#endif
};

class FixPointersVisitor : public RootCallback {
 public:
  FixPointersVisitor() : source_address_(0) {}

  virtual void visit_class(Object** p) {}

  virtual void visit_block(Object** start, Object** end);

  void set_source_address(uword address) { source_address_ = address; }

 private:
  uword source_address_;
};

class CompactingVisitor : public HeapObjectVisitor {
 public:
  CompactingVisitor(OldSpace* space, FixPointersVisitor* fix_pointers_visitor);

  virtual void chunk_start(Chunk* chunk) {
    GcMetadata::initialize_starts_for_chunk(chunk);
    uint32* last_bits = GcMetadata::mark_bits_for(chunk->usable_end());
    // When compacting the heap, we skip dead objects.  In order to do this
    // faster when we have hit a dead object we use the mark bits to find the
    // next live object, rather than stepping one object at a time and calling
    // Size() on each dead object.  To ensure that we don't go over the edge of
    // a chunk into the next chunk, we mark the end-of-chunk sentinel live.
    // This is done after the mark bits have been counted.
    *last_bits |= 1u << 31;
  }

  virtual uword visit(HeapObject* object);

  uword used() const { return used_; }

 private:
  uword used_;
  GcMetadata::Destination dest_;
  FixPointersVisitor* fix_pointers_visitor_;
};

class SweepingVisitor : public HeapObjectVisitor {
 public:
  explicit SweepingVisitor(OldSpace* space);

  virtual void chunk_start(Chunk* chunk) {
    GcMetadata::initialize_starts_for_chunk(chunk);
  }

  virtual uword visit(HeapObject* object);

  virtual void chunk_end(Chunk* chunk, uword end) {
    add_free_list_chunk(end);
    GcMetadata::clear_mark_bits_for(chunk);
  }

  uword used() const { return used_; }

 private:
  void add_free_list_chunk(uword free_end_);

  FreeList* free_list_;
  uword free_start_;
  int used_;
};

}  // namespace toit
