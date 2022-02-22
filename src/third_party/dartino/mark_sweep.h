// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef SRC_VM_MARK_SWEEP_H_
#define SRC_VM_MARK_SWEEP_H_

#include "src/shared/utils.h"
#include "src/vm/object.h"
#include "src/vm/program.h"
#include "src/vm/process.h"

namespace dartino {

class MarkingStack {
 public:
  MarkingStack() : next_(&backing_[0]), limit_(&backing_[kChunkSize]) {}

  void Push(HeapObject* object) {
    ASSERT(GCMetadata::IsMarked(object));
    if (next_ < limit_) {
      *(next_++) = object;
    } else {
      overflowed_ = true;
      GCMetadata::MarkStackOverflow(object);
    }
  }

  bool IsEmpty() { return next_ == &backing_[0]; }
  bool IsOverflowed() { return overflowed_; }
  void ClearOverflow() { overflowed_ = false; }

  void Empty(PointerVisitor* visitor);
  void Process(PointerVisitor* visitor, Space* old_space, Space* new_space);

 private:
  static const int kChunkSize = 128;
  HeapObject** next_;
  HeapObject** limit_;
  HeapObject* backing_[kChunkSize];
  bool overflowed_ = false;
};

class MarkingVisitor : public PointerVisitor {
 public:
  MarkingVisitor(SemiSpace* new_space, MarkingStack* marking_stack,
                 Stack** stack_chain = NULL)
      : stack_chain_(stack_chain),
        new_space_address_(new_space->start()),
        new_space_size_(new_space->size()),
        marking_stack_(marking_stack),
        number_of_stacks_(0) {}

  virtual void VisitClass(Object** p) {}

  virtual void VisitBlock(Object** start, Object** end) {
    // Mark live all HeapObjects pointed to by pointers in [start, end)
    for (Object** p = start; p < end; p++) MarkPointer(*p);
  }

  int number_of_stacks() const { return number_of_stacks_; }

 private:
  void ChainStack(Stack* stack) {
    number_of_stacks_++;
    stack->set_next(*stack_chain_);
    *stack_chain_ = stack;
  }

  void ALWAYS_INLINE MarkPointer(Object* object) {
    if (!GCMetadata::InNewOrOldSpace(object)) return;
    HeapObject* heap_object = HeapObject::cast(object);
    if (!GCMetadata::MarkGreyIfNotMarked(heap_object)) {
      if (stack_chain_ != NULL && heap_object->IsStack()) {
        ChainStack(Stack::cast(heap_object));
      }
      marking_stack_->Push(heap_object);
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
    memset(buckets_, 0, kNumberOfBuckets * sizeof(FreeListChunk*));
  }
#endif

  void AddChunk(uword free_start, uword free_size) {
    // If the chunk is too small to be turned into an actual
    // free list chunk we turn it into fillers to be coalesced
    // with other free chunks later.
    if (free_size < FreeListChunk::kSize) {
      ASSERT(free_size <= 2 * kPointerSize);
      Object** free_address = reinterpret_cast<Object**>(free_start);
      for (uword i = 0; i * kPointerSize < free_size; i++) {
        free_address[i] = StaticClassStructures::one_word_filler_class();
      }
      return;
    }
    // Large enough to add a free list chunk.
    FreeListChunk* result = FreeListChunk::CreateAt(free_start, free_size);
    int bucket = Utils::HighestBit(free_size) - 1;
    if (bucket >= kNumberOfBuckets) bucket = kNumberOfBuckets - 1;
    result->set_next_chunk(buckets_[bucket]);
    buckets_[bucket] = result;
  }

  FreeListChunk* GetChunk(uword min_size) {
    int smallest_bucket = Utils::HighestBit(min_size);
    ASSERT(smallest_bucket > 0);

    // Locate largest chunk in free list guaranteed to satisfy the
    // allocation.
    for (int i = kNumberOfBuckets - 1; i >= smallest_bucket; i--) {
      FreeListChunk* result = buckets_[i];
      if (result != NULL) {
        ASSERT(result->size() >= min_size);
        FreeListChunk* next_chunk =
            reinterpret_cast<FreeListChunk*>(result->next_chunk());
        result->set_next_chunk(NULL);
        buckets_[i] = next_chunk;
        return result;
      }
    }

    // Search the bucket containing chunks that could, but are not
    // guaranteed to, satisfy the allocation.
    if (smallest_bucket > kNumberOfBuckets) smallest_bucket = kNumberOfBuckets;
    FreeListChunk* previous = reinterpret_cast<FreeListChunk*>(NULL);
    FreeListChunk* current = buckets_[smallest_bucket - 1];
    while (current != NULL) {
      if (current->size() >= min_size) {
        if (previous != NULL) {
          previous->set_next_chunk(current->next_chunk());
        } else {
          buckets_[smallest_bucket - 1] =
              reinterpret_cast<FreeListChunk*>(current->next_chunk());
        }
        current->set_next_chunk(NULL);
        return current;
      }
      previous = current;
      current = reinterpret_cast<FreeListChunk*>(current->next_chunk());
    }

    return NULL;
  }

  void Clear() {
    for (int i = 0; i < kNumberOfBuckets; i++) {
      buckets_[i] = NULL;
    }
  }

  void Merge(FreeList* other) {
    for (int i = 0; i < kNumberOfBuckets; i++) {
      FreeListChunk* chunk = other->buckets_[i];
      if (chunk != NULL) {
        FreeListChunk* last_chunk = chunk;
        while (last_chunk->next_chunk() != NULL) {
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
  static const int kNumberOfBuckets = 12;
#if defined(_MSC_VER)
  // Work around Visual Studo 2013 bug 802058
  FreeListChunk* buckets_[kNumberOfBuckets];
#else
  FreeListChunk* buckets_[kNumberOfBuckets] = {NULL};
#endif
};

class FixPointersVisitor : public PointerVisitor {
 public:
  FixPointersVisitor() : source_address_(0) {}

  virtual void VisitClass(Object** p) {}

  virtual void VisitBlock(Object** start, Object** end);

  virtual void AboutToVisitStack(Stack* stack);

  void set_source_address(uword address) { source_address_ = address; }

 private:
  uword source_address_;
};

class CompactingVisitor : public HeapObjectVisitor {
 public:
  CompactingVisitor(OldSpace* space, FixPointersVisitor* fix_pointers_visitor);

  virtual void ChunkStart(Chunk* chunk) {
    GCMetadata::InitializeStartsForChunk(chunk);
    uint32* last_bits = GCMetadata::MarkBitsFor(chunk->usable_end());
    // When compacting the heap, we skip dead objects.  In order to do this
    // faster when we have hit a dead object we use the mark bits to find the
    // next live object, rather than stepping one object at a time and calling
    // Size() on each dead object.  To ensure that we don't go over the edge of
    // a chunk into the next chunk, we mark the end-of-chunk sentinel live.
    // This is done after the mark bits have been counted.
    *last_bits |= 1u << 31;
  }

  virtual uword Visit(HeapObject* object);

  uword used() const { return used_; }

 private:
  uword used_;
  GCMetadata::Destination dest_;
  FixPointersVisitor* fix_pointers_visitor_;
};

class SweepingVisitor : public HeapObjectVisitor {
 public:
  explicit SweepingVisitor(OldSpace* space);

  virtual void ChunkStart(Chunk* chunk) {
    GCMetadata::InitializeStartsForChunk(chunk);
  }

  virtual uword Visit(HeapObject* object);

  virtual void ChunkEnd(Chunk* chunk, uword end) {
    AddFreeListChunk(end);
    GCMetadata::ClearMarkBitsFor(chunk);
  }

  uword used() const { return used_; }

 private:
  void AddFreeListChunk(uword free_end_);

  FreeList* free_list_;
  uword free_start_;
  int used_;
};

}  // namespace dartino

#endif  // SRC_VM_MARK_SWEEP_H_
