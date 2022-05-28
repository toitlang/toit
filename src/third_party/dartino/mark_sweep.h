// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
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
  explicit MarkingStack(Program* program)
    : program_(program)
    , next_(&backing_[0])
    , limit_(&backing_[CHUNK_SIZE]) {}

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
  Program* program_;
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

  virtual void do_roots(Object** start, int length) {
    Object** end = start + length;
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

class FixPointersVisitor : public RootCallback {
 public:
  FixPointersVisitor() {}

  virtual void do_roots(Object** start, int length);
};

class CompactingVisitor : public HeapObjectVisitor {
 public:
  CompactingVisitor(Program* program, OldSpace* space, FixPointersVisitor* fix_pointers_visitor);

  virtual void chunk_start(Chunk* chunk) override {
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

  virtual uword visit(HeapObject* object) override;

  uword used() const { return used_; }

 private:
  uword used_;
  GcMetadata::Destination dest_;
  FixPointersVisitor* fix_pointers_visitor_;
};

class SweepingVisitor : public HeapObjectVisitor {
 public:
  SweepingVisitor(Program* program, OldSpace* space);

  virtual void chunk_start(Chunk* chunk) override {
    GcMetadata::initialize_starts_for_chunk(chunk);
  }

  virtual uword visit(HeapObject* object) override;

  virtual void chunk_end(Chunk* chunk, uword end) override {
    add_free_list_region(end);
    GcMetadata::clear_mark_bits_for_chunk(chunk);
  }

  uword used() const { return used_; }

 private:
  void add_free_list_region(uword free_end_);

  FreeList* free_list_;
  uword free_start_;
  int used_;
};

}  // namespace toit
