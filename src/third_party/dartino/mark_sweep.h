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
  MarkingVisitor(SemiSpace* new_space, MarkingStack* marking_stack,
                 Stack** stack_chain = null)
      : stack_chain_(stack_chain),
        new_space_address_(new_space->start()),
        new_space_size_(new_space->size()),
        marking_stack_(marking_stack),
        number_of_stacks_(0) {}

  virtual void visit_class(Object** p) {}

  virtual void visit_block(Object** start, Object** end) {
    // Mark live all HeapObjects pointed to by pointers in [start, end)
    for (Object** p = start; p < end; p++) mark_pointer(*p);
  }

  int number_of_stacks() const { return number_of_stacks_; }

 private:
  void chain_stack(Stack* stack) {
    number_of_stacks_++;
    stack->set_next(*stack_chain_);
    *stack_chain_ = stack;
  }

  void INLINE mark_pointer(Object* object) {
    if (!GcMetadata::in_new_or_old_space(object)) return;
    HeapObject* heap_object = HeapObject::cast(object);
    if (!GcMetadata::mark_grey_if_not_marked(heap_object)) {
      if (stack_chain_ != null && heap_object->is_stack()) {
        chain_stack(Stack::cast(heap_object));
      }
      marking_stack_->push(heap_object);
    }
  }

  Stack** stack_chain_;
  uword new_space_address_;
  uword new_space_size_;
  MarkingStack* marking_stack_;
  int number_of_stacks_;
};

class FreeList {
 public:
#if defined(_MSC_VER)
  // Work around Visual Studo 2013 bug 802058
  FreeList(void) {
    memset(buckets_, 0, NUMBER_OF_BUCKETS * sizeof(FreeListChunk*));
  }
#endif

  void AddChunk(uword free_start, uword free_size) {
    // If the chunk is too small to be turned into an actual
    // free list chunk we turn it into fillers to be coalesced
    // with other free chunks later.
    if (free_size < FreeListChunk::SIZE) {
      ASSERT(free_size <= 2 * WORD_SIZE);
      Object** free_address = reinterpret_cast<Object**>(free_start);
      for (uword i = 0; i * WORD_SIZE < free_size; i++) {
        free_address[i] = StaticClassStructures::one_word_filler_class();
      }
      return;
    }
    // Large enough to add a free list chunk.
    FreeListChunk* result = FreeListChunk::create_at(free_start, free_size);
    int bucket = Utils::highest_bit(free_size) - 1;
    if (bucket >= NUMBER_OF_BUCKETS) bucket = NUMBER_OF_BUCKETS - 1;
    result->set_next_chunk(buckets_[bucket]);
    buckets_[bucket] = result;
  }

  FreeListChunk* get_chunk(uword min_size) {
    int smallest_bucket = Utils::highest_bit(min_size);
    ASSERT(smallest_bucket > 0);

    // Locate largest chunk in free list guaranteed to satisfy the
    // allocation.
    for (int i = NUMBER_OF_BUCKETS - 1; i >= smallest_bucket; i--) {
      FreeListChunk* result = buckets_[i];
      if (result != null) {
        ASSERT(result->size() >= min_size);
        FreeListChunk* next_chunk =
            reinterpret_cast<FreeListChunk*>(result->next_chunk());
        result->set_next_chunk(null);
        buckets_[i] = next_chunk;
        return result;
      }
    }

    // Search the bucket containing chunks that could, but are not
    // guaranteed to, satisfy the allocation.
    if (smallest_bucket > NUMBER_OF_BUCKETS) smallest_bucket = NUMBER_OF_BUCKETS;
    FreeListChunk* previous = reinterpret_cast<FreeListChunk*>(null);
    FreeListChunk* current = buckets_[smallest_bucket - 1];
    while (current != null) {
      if (current->size() >= min_size) {
        if (previous != null) {
          previous->set_next_chunk(current->next_chunk());
        } else {
          buckets_[smallest_bucket - 1] =
              reinterpret_cast<FreeListChunk*>(current->next_chunk());
        }
        current->set_next_chunk(null);
        return current;
      }
      previous = current;
      current = reinterpret_cast<FreeListChunk*>(current->next_chunk());
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
      FreeListChunk* chunk = other->buckets_[i];
      if (chunk != null) {
        FreeListChunk* last_chunk = chunk;
        while (last_chunk->next_chunk() != null) {
          last_chunk = FreeListChunk::cast(last_chunk->next_chunk());
        }
        last_chunk->set_next_chunk(buckets_[i]);
        buckets_[i] = chunk;
      }
    }
  }

 private:
  // Buckets of power of two sized free lists chunks. Bucket i
  // contains chunks of size larger than 2 ** (i + 1).
  static const int NUMBER_OF_BUCKETS = 12;
#if defined(_MSC_VER)
  // Work around Visual Studo 2013 bug 802058
  FreeListChunk* buckets_[NUMBER_OF_BUCKETS];
#else
  FreeListChunk* buckets_[NUMBER_OF_BUCKETS] = {null};
#endif
};

class FixPointersVisitor : public RootCallback {
 public:
  FixPointersVisitor() : source_address_(0) {}

  virtual void visit_class(Object** p) {}

  virtual void visit_block(Object** start, Object** end);

  virtual void about_to_visit_stack(Stack* stack);

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
