// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#pragma once

#include "../../top.h"

#include "../../objects.h"
#include "object_memory.h"
#include "gc_metadata.h"

namespace toit {

// Heap represents the container for all HeapObjects.
class Heap {
 public:
  // Allocate raw object. Returns a failure if a garbage collection is
  // needed and causes a fatal error if a GC cannot free up enough memory
  // for the object.
  Object* allocate(uword size);

  // Called when an allocation fails in the semispace.  Usually returns a
  // retry-after-GC failure, but may divert large allocations to an old space.
  virtual Object* handle_allocation_failure(uword size) = 0;

  // Iterate over all objects in the heap.
  virtual void iterate_objects(HeapObjectVisitor* visitor) {
    space_->iterate_objects(visitor);
  }

  // Flush will write cached values back to object memory.
  // Flush must be called before traveral of heap.
  virtual void flush() { space_->flush(); }

  // Returns the number of bytes allocated in the space.
  virtual int used() { return space_->used(); }

  // Returns the number of bytes allocated in the space and via foreign memory.
  uword used_total() { return used() + foreign_memory_; }

  // Max memory that can be added by adding new chunks.  Accounts for whole
  // chunks, not just the used memory in them.
  virtual uword max_expansion() { return UNLIMITED_EXPANSION; }

  SemiSpace* space() { return space_; }

  void replace_space(SemiSpace* space);
  SemiSpace* take_space();

  uword used_foreign_memory() { return foreign_memory_; }

#ifdef DEBUG
  // Used for debugging.  Give it an address, and it will tell you where there
  // are pointers to that address.  If the address is part of the heap it will
  // also tell you which part.  Reduced functionality if you are not on Linux,
  // since it uses the /proc filesystem.
  // To actually call this from gdb you probably need to remove the
  // --gc-sections flag from the linker in the build scripts.
  virtual void find(uword word);
#endif

  // For asserts.
  virtual bool is_two_space_heap() { return false; }

 protected:
  friend class Scheduler;
  friend class Program;
  friend class NoAllocationScope;

  Heap(Program* program, SemiSpace* existing_space);
  explicit Heap(Program* program);
  virtual ~Heap();

  static const uword UNLIMITED_EXPANSION = 0x80000000u - TOIT_PAGE_SIZE;

  // Adjust the allocation budget based on the current heap size.
  void adjust_allocation_budget() { space()->adjust_allocation_budget(0); }

  SemiSpace* space_;

  // The number of bytes of foreign memory heap objects are holding on to.
  uword foreign_memory_;

#ifdef DEBUG
  void IncrementNoAllocation() { ++no_allocation_; }
  void DecrementNoAllocation() { --no_allocation_; }
#endif

 private:
  int no_allocation_ = 0;
};

class TwoSpaceHeap : public Heap {
 public:
  TwoSpaceHeap();
  virtual ~TwoSpaceHeap();

  // Returns false for allocation failure.
  bool initialize();

  OldSpace* old_space() { return old_space_; }
  SemiSpace* unused_space() { return unused_semispace_; }

  void swap_semi_spaces();

  // Iterate over all objects in the heap.
  virtual void iterate_objects(HeapObjectVisitor* visitor) {
    Heap::iterate_objects(visitor);
    old_space_->iterate_objects(visitor);
  }

  // Flush will write cached values back to object memory.
  // Flush must be called before traveral of heap.
  virtual void flush() {
    Heap::flush();
    old_space_->flush();
  }

  // Returns the number of bytes allocated in the space.
  virtual int used() { return old_space_->used() + Heap::used(); }

#ifdef DEBUG
  virtual void find(uword word);
#endif

  void adjust_old_allocation_budget() {
    old_space()->adjust_allocation_budget(foreign_memory_);
  }

  virtual Object* handle_allocation_failure(uword size) {
    if (size >= (semispace_size_ >> 1)) {
      uword result = old_space_->allocate(size);
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

  virtual bool is_two_space_heap() { return true; }

  bool has_empty_new_space() { return space_->top() == space_->single_chunk_start(); }

  void allocated_foreign_memory(uword size);

  void freed_foreign_memory(uword size);

  virtual uword max_expansion();

 private:
  friend class GenerationalScavengeVisitor;

  // Allocate or deallocate the pages used for heap metadata.
  void manage_metadata(bool allocate);

  OldSpace* old_space_;
  SemiSpace* unused_semispace_;
  uword water_mark_;
  uword max_size_;
  uword semispace_size_;
};

// Helper class for copying HeapObjects.
class GenerationalScavengeVisitor : public PointerVisitor {
 public:
  explicit GenerationalScavengeVisitor(Program* program, TwoSpaceHeap* heap)
      : program_(program),
        to_start_(heap->unused_semispace_->single_chunk_start()),
        to_size_(heap->unused_semispace_->single_chunk_size()),
        from_start_(heap->space()->single_chunk_start()),
        from_size_(heap->space()->single_chunk_size()),
        to_(heap->unused_semispace_),
        old_(heap->old_space()),
        record_(&dummy_record_),
        water_mark_(heap->water_mark_) {}

  virtual void visit(Object** p) { visit_block(p, p + 1); }

  inline bool in_from_space(Object* object) {
    if (object->is_smi()) return false;
    return reinterpret_cast<uword>(object) - from_start_ < from_size_;
  }

  inline bool in_to_space(HeapObject* object) {
    return reinterpret_cast<uword>(object) - to_start_ < to_size_;
  }

  virtual void visit_block(Object** start, Object** end);

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
