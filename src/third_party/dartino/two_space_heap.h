// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#pragma once

#include "../../top.h"

#include "../../objects.h"
#include "object_memory.h"
#include "gc_metadata.h"

namespace toit {

class HeapObjectFunctionVisitor : public HeapObjectVisitor {
 public:
  HeapObjectFunctionVisitor(Program* program, const std::function<void (HeapObject*)>& func)
    : HeapObjectVisitor(program)
    , _func(func) {}

  virtual uword visit(HeapObject* object) override {
    _func(object);
    return object->size(program_);
  }

 private:
  const std::function<void (HeapObject*)>& _func;
};

// TwoSpaceHeap represents the container for all HeapObjects.
class TwoSpaceHeap {
 public:
  TwoSpaceHeap(Program* program, ObjectHeap* process_heap, Chunk* chunk);
  ~TwoSpaceHeap();

  // Allocate raw object. Returns null if a garbage collection is
  // needed.
  HeapObject* allocate(uword size);

  SemiSpace* new_space() { return &semi_space_; }

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

  OldSpace* old_space() { return &old_space_; }

  word size() { return old_space_.size() + new_space()->size(); }

  void swap_semi_spaces(SemiSpace& from, SemiSpace& to);

  Process* process();

  // Iterate over all objects in the heap.
  void iterate_objects(HeapObjectVisitor* visitor) {
    semi_space_.iterate_objects(visitor);
    old_space_.iterate_objects(visitor);
  }

  void do_objects(const std::function<void (HeapObject*)>& func) {
    HeapObjectFunctionVisitor visitor(program_, func);
    iterate_objects(&visitor);
  }

  // Flush will write cached values back to object memory.
  // Flush must be called before traveral of heap.
  void flush() {
    semi_space_.flush();
    old_space_.flush();
  }

  // Returns the number of bytes allocated in the space.
  int used() { return old_space_.used() + semi_space_.used(); }

  HeapObject* new_space_allocation_failure(uword size);

  bool has_empty_new_space() { return semi_space_.top() == semi_space_.single_chunk_start(); }

  void allocated_foreign_memory(uword size);

  void freed_foreign_memory(uword size);

  bool collect_new_space(bool try_hard);
  void collect_old_space(bool force_compact);
  bool collect_old_space_if_needed(bool force_compact, bool force);
  bool perform_garbage_collection(bool force_compact);
  bool cross_process_gc_needed() const { return malloc_failed_; }
  void report_malloc_failed() { malloc_failed_ = true; }
  void sweep_heap();
  void compact_heap();
  void set_promotion_failed() { old_space_.set_promotion_failed(true); }

  uword total_bytes_allocated();

  word max_external_allocation();

 private:
  friend class ScavengeVisitor;

  Program* program_;
  ObjectHeap* process_heap_;
  OldSpace old_space_;
  SemiSpace semi_space_;
  uword water_mark_;
  uword semi_space_size_;
  uword total_bytes_allocated_ = 0;
  bool malloc_failed_ = false;
};

// Helper class for copying HeapObjects.
class ScavengeVisitor : public RootCallback {
 public:
  explicit ScavengeVisitor(Program* program, TwoSpaceHeap* heap, Chunk* to_chunk)
      : program_(program),
        to_start_(to_chunk->start()),
        to_size_(to_chunk->size()),
        from_start_(heap->new_space()->single_chunk_start()),
        from_size_(heap->new_space()->single_chunk_size()),
        to_(program, to_chunk),
        old_(heap->old_space()),
        record_(&dummy_record_),
        water_mark_(heap->water_mark_) {}

  SemiSpace* to_space() { return &to_; }

  void complete_scavenge() {
    bool work_found = true;
    while (work_found) {
      work_found = to_.complete_scavenge(this);
      work_found |= old_->complete_scavenge(this);
    }
  }

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

  void set_record_to_dummy_address() {
    record_ = &dummy_record_;
  }

  void set_record_new_space_pointers(uint8* p) { record_ = p; }

 private:
  template <class SomeSpace>
  static inline HeapObject* clone_into_space(Program* program, HeapObject* original, SomeSpace* to);

  Program* program_;
  uword to_start_;
  uword to_size_;
  uword from_start_;
  uword from_size_;
  SemiSpace to_;
  OldSpace* old_;
  bool trigger_old_space_gc_ = false;
  uint8* record_;
  // Avoid checking for null by having a default place to write the remembered
  // set byte.
  uint8 dummy_record_;
  uword water_mark_;
};

}  // namespace toit
