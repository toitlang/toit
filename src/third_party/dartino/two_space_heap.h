// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#pragma once

#include "../../top.h"

#include "../../objects.h"
#include "object_memory.h"
#include "gc_metadata.h"

namespace toit {

// TwoSpaceHeap represents the container for all HeapObjects.
class TwoSpaceHeap {
 public:
  TwoSpaceHeap(Program* program, ObjectHeap* process_heap, Chunk* chunk_1, Chunk* chunk_2);
  ~TwoSpaceHeap();

  // Allocate raw object. Returns null if a garbage collection is
  // needed.
  HeapObject* allocate(uword size);

  // Max memory that can be added by adding new chunks.  Accounts for whole
  // chunks, not just the used memory in them.
  uword max_expansion() { return UNLIMITED_EXPANSION; }

  SemiSpace* space() { return semi_space_; }

  SemiSpace* take_space();

#ifdef DEBUG
  // Used for debugging.  Give it an address, and it will tell you where there
  // are pointers to that address.  If the address is part of the heap it will
  // also tell you which part.  Reduced functionality if you are not on Linux,
  // since it uses the /proc filesystem.
  // To actually call this from gdb you probably need to remove the
  // --gc-sections flag from the linker in the build scripts.
  void find(uword word);
#endif

  void validate();

  // Returns false for allocation failure.
  bool initialize();

  OldSpace* old_space() { return &old_space_; }
  SemiSpace* unused_space() { return unused_semi_space_; }

  void swap_semi_spaces();

  // Iterate over all objects in the heap.
  void iterate_objects(HeapObjectVisitor* visitor) {
    semi_space_->iterate_objects(visitor);
    old_space_.iterate_objects(visitor);
  }

  // Flush will write cached values back to object memory.
  // Flush must be called before traveral of heap.
  void flush() {
    semi_space_->flush();
    old_space_.flush();
  }

  // Returns the number of bytes allocated in the space.
  int used() { return old_space_.used() + semi_space_->used(); }

  HeapObject* new_space_allocation_failure(uword size) {
    if (size >= (semi_space_size_ >> 1)) {
      uword result = old_space_.allocate(size);
      if (result != 0) {
        // The code that populates newly allocated objects assumes that they
        // are in new space and does not have a write barrier.  We mark the
        // object dirty immediately, so it is checked by the next GC.
        GcMetadata::insert_into_remembered_set(result);
        return HeapObject::from_address(result);
      }
    }
    return null;
  }

  bool has_empty_new_space() { return semi_space_->top() == semi_space_->single_chunk_start(); }

  void allocated_foreign_memory(uword size);

  void freed_foreign_memory(uword size);

  void collect_new_space();
  void collect_old_space();
  void collect_old_space_if_needed(bool force);
  void perform_shared_garbage_collection();
  void sweep_shared_heap();
  void compact_shared_heap();

 private:
  static const uword UNLIMITED_EXPANSION = 0x80000000u - TOIT_PAGE_SIZE;

  friend class GenerationalScavengeVisitor;

  Program* program_;
  ObjectHeap* process_heap_;
  OldSpace old_space_;
  SemiSpace semi_space_a_;
  SemiSpace semi_space_b_;
  SemiSpace* semi_space_;
  SemiSpace* unused_semi_space_;
  uword water_mark_;
  uword max_size_;
  uword semi_space_size_;
};

// Helper class for copying HeapObjects.
class GenerationalScavengeVisitor : public RootCallback {
 public:
  explicit GenerationalScavengeVisitor(Program* program, TwoSpaceHeap* heap)
      : program_(program),
        to_start_(heap->unused_semi_space_->single_chunk_start()),
        to_size_(heap->unused_semi_space_->single_chunk_size()),
        from_start_(heap->space()->single_chunk_start()),
        from_size_(heap->space()->single_chunk_size()),
        to_(heap->unused_semi_space_),
        old_(heap->old_space()),
        record_(&dummy_record_),
        water_mark_(heap->water_mark_) {}

  virtual void do_root(Object** p) { do_roots(p, 1); }

  inline bool in_from_space(Object* object) {
    if (object->is_smi()) return false;
    return reinterpret_cast<uword>(object) - from_start_ < from_size_;
  }

  inline bool in_to_space(HeapObject* object) {
    return reinterpret_cast<uword>(object) - to_start_ < to_size_;
  }

  virtual void do_roots(Object** start, int count);

  bool trigger_old_space_gc() { return trigger_old_space_gc_; }

  void set_record_new_space_pointers(uint8* p) { record_ = p; }

 private:
  template <class SomeSpace>
  static inline HeapObject* clone_in_to_space(Program* program, HeapObject* original, SomeSpace* to);

  Program* program_;
  uword to_start_;
  uword to_size_;
  uword from_start_;
  uword from_size_;
  SemiSpace* to_;
  OldSpace* old_;
  bool trigger_old_space_gc_ = false;
  uint8* record_;
  // Avoid checking for null by having a default place to write the remembered
  // set byte.
  uint8 dummy_record_;
  uword water_mark_;
};

}  // namespace toit
