// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "sandbox_gc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flags.h"
#include "heap.h"
#include "interpreter.h"
#include "objects_inline.h"
#include "os.h"
#include "primitive_policy.h"
#include "process.h"
#include "utils.h"
#include "third_party/dartino/two_space_heap.h"

#if defined(TOIT_LINUX)
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace toit {

// --- Selection ---------------------------------------------------------------

enum SandboxGcMode {
  SANDBOX_GC_GENERATIONAL,
  SANDBOX_GC_COPYING,      // Untrusted processes.
  SANDBOX_GC_COPYING_ALL,  // Every process (testing the collector).
  SANDBOX_GC_INPLACE,      // Untrusted processes, the in-place collector (hosts).
  SANDBOX_GC_INPLACE_ALL,  // Every process, the in-place collector (hosts).
};

static SandboxGcMode sandbox_gc_mode() {
#ifdef TOIT_FREERTOS
  return SANDBOX_GC_GENERATIONAL;
#else
  static int mode = -1;
  if (mode < 0) {
    const char* value = getenv("TOIT_SANDBOX_GC");
    if (value != null && strcmp(value, "copying") == 0) {
      mode = SANDBOX_GC_COPYING;
    } else if (value != null && strcmp(value, "copying-all") == 0) {
      mode = SANDBOX_GC_COPYING_ALL;
    } else if (value != null && strcmp(value, "inplace") == 0) {
      mode = SANDBOX_GC_INPLACE;
    } else if (value != null && strcmp(value, "inplace-all") == 0) {
      mode = SANDBOX_GC_INPLACE_ALL;
    } else {
      mode = SANDBOX_GC_GENERATIONAL;
    }
  }
  return static_cast<SandboxGcMode>(mode);
#endif
}

static bool sandbox_inplace_gc_selected() {
  SandboxGcMode mode = sandbox_gc_mode();
  return mode == SANDBOX_GC_INPLACE || mode == SANDBOX_GC_INPLACE_ALL;
}

bool sandbox_copying_gc_wanted(Process* process) {
  if (process->program() == null) return false;
  switch (sandbox_gc_mode()) {
    case SANDBOX_GC_GENERATIONAL: return false;
    case SANDBOX_GC_COPYING: return process->policy()->is_untrusted();
    case SANDBOX_GC_COPYING_ALL: return true;
    case SANDBOX_GC_INPLACE: return process->policy()->is_untrusted();
    case SANDBOX_GC_INPLACE_ALL: return true;
  }
  return false;
}

// --- The collector -----------------------------------------------------------

// One collection. The interface it needs from the runtime is what a Rust
// port would get through its FFI: the space (its page list and allocation
// window), a page allocator (ObjectMemory), the roots (ObjectHeap::
// iterate_roots and the finalizer lists, which call back into do_roots and
// is_alive), and the object layout (HeapObject::size and roots_do).
class SandboxCopyingCollector : public RootCallback, public LivenessOracle {
 public:
  explicit SandboxCopyingCollector(TwoSpaceHeap* heap)
      : program_(heap->program_)
      , heap_(heap)
      , space_(heap->new_space()) {}

  ~SandboxCopyingCollector() {
    if (ranges_ != inline_ranges_) free(ranges_);
  }

  void collect();

  uword from_pages() const { return from_pages_; }
  uword to_pages() const { return to_pages_; }
  uword copied_bytes() const { return copied_bytes_; }
  uword waste() const { return waste_; }
  bool is_from_space(HeapObject* object) const { return in_from_space(object); }

  // RootCallback.
  void do_roots(Object** roots, word length) override {
    for (word i = 0; i < length; i++) {
      scavenge_slot(&roots[i]);
      if (weak_phase_) forward_weak_container(&roots[i]);
    }
  }

  // Every collection is a full one: stacks shrink as in a mark-sweep.
  bool shrink_stacks() const override { return true; }

  // The fields of a weak map are not traced; the finalizer pass handles them
  // (WeakMapFinalizerNode::weak_processing), as in a mark-sweep.
  bool skip_marking(HeapObject* object) const override {
    if (!object->has_active_finalizer()) return false;
    if (!is_instance(object)) return false;
    return object->class_id() == program_->map_class_id();
  }

  // LivenessOracle: objects outside from-space (program heap, already
  // copied) are alive; a from-space object is alive once it is copied.
  bool is_alive(HeapObject* object) override {
    if (!in_from_space(object)) return true;
    return object->has_forwarding_address();
  }

  bool has_active_finalizer(HeapObject* object) override {
    return object->has_active_finalizer();
  }

 private:
  static const int INLINE_RANGES = 32;

  Program* program_;
  TwoSpaceHeap* heap_;
  SemiSpace* space_;
  ChunkList from_;
  // The from-space pages as sorted [start, end) pairs.
  uword* ranges_ = inline_ranges_;
  uword inline_ranges_[2 * INLINE_RANGES];
  word range_count_ = 0;
  // Cheney scan position: the next object to scan in to-space.
  ChunkListIterator scan_chunk_ = ChunkListIterator(null);  // Valid once scan_started_.
  bool scan_started_ = false;
  uword scan_ = 0;
  bool weak_phase_ = false;
  uword from_pages_ = 0;
  uword to_pages_ = 0;
  uword copied_bytes_ = 0;
  uword waste_ = 0;

  void detach_from_space();
  bool in_from_space(HeapObject* object) const;
  inline Object* forward(Object* value);
  inline void scavenge_slot(Object** slot);
  HeapObject* copy(HeapObject* object);
  uword allocate_in_to_space(uword size);
  void scan();
  void forward_weak_container(Object** slot);
  void forward_elements(Array* array);
  void free_from_space();
#ifndef TOIT_FREERTOS
  void verify_and_poison();
#endif
};

void SandboxCopyingCollector::detach_from_space() {
  space_->flush();
  word count = 0;
  for (auto chunk : space_->chunk_list_) {
    USE(chunk);
    count++;
  }
  if (count > INLINE_RANGES) {
    ranges_ = static_cast<uword*>(malloc(2 * count * sizeof(uword)));
    if (ranges_ == null) FATAL("sandbox copying GC: no memory for the page table");
  }
  while (Chunk* chunk = space_->chunk_list_.remove_first()) {
    from_.append(chunk);
    // Insertion sort by start address (a few pages).
    word i = range_count_++;
    while (i > 0 && ranges_[2 * (i - 1)] > chunk->start()) {
      ranges_[2 * i] = ranges_[2 * (i - 1)];
      ranges_[2 * i + 1] = ranges_[2 * (i - 1) + 1];
      i--;
    }
    ranges_[2 * i] = chunk->start();
    ranges_[2 * i + 1] = chunk->end();
    from_pages_ += chunk->size() / TOIT_PAGE_SIZE;
  }
  space_->top_ = 0;
  space_->limit_ = 0;
  heap_->copying_closed_used_ = 0;
}

bool SandboxCopyingCollector::in_from_space(HeapObject* object) const {
  uword address = reinterpret_cast<uword>(object);
  word low = 0;
  word high = range_count_;
  while (low < high) {
    word mid = (low + high) >> 1;
    if (address < ranges_[2 * mid]) {
      high = mid;
    } else if (address >= ranges_[2 * mid + 1]) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

inline Object* SandboxCopyingCollector::forward(Object* value) {
  if (is_smi(value)) return value;
  HeapObject* object = HeapObject::cast(value);
  if (!in_from_space(object)) return value;
  if (object->has_forwarding_address()) return object->forwarding_address();
  return copy(object);
}

inline void SandboxCopyingCollector::scavenge_slot(Object** slot) {
  Object* value = *slot;
  Object* forwarded = forward(value);
  if (forwarded != value) *slot = forwarded;
}

HeapObject* SandboxCopyingCollector::copy(HeapObject* object) {
  uword size = object->size(program_);
  uword destination = allocate_in_to_space(size);
  memcpy(reinterpret_cast<void*>(destination), reinterpret_cast<void*>(reinterpret_cast<uword>(object) - Object::HEAP_TAG), size);
  HeapObject* target = HeapObject::from_address(destination);
  object->set_forwarding_address(target);
  copied_bytes_ += size;
  return target;
}

uword SandboxCopyingCollector::allocate_in_to_space(uword size) {
  uword result = space_->try_allocate(size);
  if (result != 0) return result;
  if (!space_->chunk_list_.is_empty()) {
    Chunk* last = space_->chunk_list_.last();
    heap_->copying_closed_used_ += space_->top_ - last->start();
    waste_ += last->end() - space_->top_;
  }
  // To-space is taken a page at a time, outside the heap limit (it replaces
  // from-space when the collection ends). See the README for what a device
  // build must do instead of failing here.
  Chunk* chunk = ObjectMemory::allocate_chunk(space_, TOIT_PAGE_SIZE);
  if (chunk == null) FATAL("sandbox copying GC: no page for to-space");
  to_pages_++;
  space_->chunk_list_.append(chunk);
  space_->top_ = chunk->start();
  space_->limit_ = chunk->end();
  write_sentinel_at(space_->top_);
  result = space_->try_allocate(size);
  if (result == 0) FATAL("sandbox copying GC: object larger than a page");
  return result;
}

// Scans the copied objects in allocation order until the scan reaches the
// allocation top (the sentinel of the last page). Can be called again after
// more objects were copied.
void SandboxCopyingCollector::scan() {
  if (space_->chunk_list_.is_empty()) return;
  if (!scan_started_) {
    scan_chunk_ = space_->chunk_list_.begin();
    scan_ = scan_chunk_->start();
    scan_started_ = true;
  }
  while (true) {
    while (!has_sentinel_at(scan_)) {
      HeapObject* object = HeapObject::from_address(scan_);
      object->roots_do(program_, this);
      scan_ += object->size(program_);
    }
    if (*scan_chunk_ == space_->chunk_list_.last()) return;
    ++scan_chunk_;
    scan_ = scan_chunk_->start();
  }
}

// The weak-map pass (WeakMapFinalizerNode::weak_processing, zap_dead_values)
// reads the map's backing list, its array (or the large array's vector and
// arraylets) and the elements' liveness right after the shim visited the
// map's fields. In a moving collection those containers must already be
// in to-space and their elements must not be forwarding headers: copy the
// containers now and replace forwarded elements by their copies. Elements
// that are not copied yet stay in from-space and count as dead.
void SandboxCopyingCollector::forward_weak_container(Object** slot) {
  Object* value = *slot;
  if (!is_instance(value)) return;
  Instance* instance = Instance::cast(value);
  if (in_from_space(instance)) return;  // Not a copy (cannot happen after scavenge_slot).
  Smi* class_id = instance->class_id();
  if (class_id == program_->list_class_id()) {
    Object* array = forward(instance->at(Instance::LIST_ARRAY_INDEX));
    instance->at_put(Instance::LIST_ARRAY_INDEX, array);
    if (is_array(array)) {
      forward_elements(Array::cast(array));
    } else if (is_instance(array)) {
      Object* backing = array;
      forward_weak_container(&backing);  // A large array as the backing.
    }
  } else if (class_id == program_->large_array_class_id()) {
    Object* vector_object = forward(instance->at(Instance::LARGE_ARRAY_VECTOR_INDEX));
    instance->at_put(Instance::LARGE_ARRAY_VECTOR_INDEX, vector_object);
    if (!is_array(vector_object)) return;
    Array* vector = Array::cast(vector_object);
    for (word i = 0; i < vector->length(); i++) {
      Object* arraylet = forward(vector->at(i));
      vector->at_put(i, arraylet);
      if (is_array(arraylet)) forward_elements(Array::cast(arraylet));
    }
  }
}

void SandboxCopyingCollector::forward_elements(Array* array) {
  for (word i = 0; i < array->length(); i++) {
    Object* value = array->at(i);
    if (is_smi(value)) continue;
    HeapObject* object = HeapObject::cast(value);
    if (in_from_space(object) && object->has_forwarding_address()) {
      array->at_put(i, object->forwarding_address());
    }
  }
}

#ifndef TOIT_FREERTOS
// TOIT_SANDBOX_GC_VERIFY=1 (hosts only, a test of the C++ root enumeration,
// verified/gc/TRUSTED.md section 5): after a collection, no root slot the
// runtime holds (iterate_roots, the finalizer nodes) and no reference slot
// of any object of the new heap may point into from-space; then the
// from-space pages are overwritten with a poison word before they are
// freed, so that a pointer the enumeration missed reads garbage.
class FromSpaceCheck : public RootCallback {
 public:
  FromSpaceCheck(SandboxCopyingCollector* collector, const char* where) : collector_(collector), where_(where) {}
  void do_roots(Object** roots, word length) override {
    for (word i = 0; i < length; i++) {
      Object* value = roots[i];
      if (is_heap_object(value) && collector_->is_from_space(HeapObject::cast(value))) {
        FATAL("sandbox copying GC: %s slot %p still points into from-space (%p)", where_, roots + i, value);
      }
    }
  }
  bool shrink_stacks() const override { return false; }
  bool skip_marking(HeapObject* object) const override { return false; }

 private:
  SandboxCopyingCollector* collector_;
  const char* where_;
};

static bool gc_verify_enabled() {
  static int enabled = -1;
  if (enabled < 0) {
    const char* value = getenv("TOIT_SANDBOX_GC_VERIFY");
    enabled = (value != null && value[0] != '0') ? 1 : 0;
  }
  return enabled == 1;
}

void SandboxCopyingCollector::verify_and_poison() {
  if (!gc_verify_enabled()) return;
  ObjectHeap* roots = heap_->process_heap_;
  FromSpaceCheck root_check(this, "root");
  roots->iterate_roots(&root_check);
  FromSpaceCheck finalizer_check(this, "finalizer");
  roots->iterate_finalization_roots(&finalizer_check);
  FromSpaceCheck heap_check(this, "heap");
  for (auto chunk : space_->chunk_list_) {
    uword top = chunk == space_->chunk_list_.last() ? space_->top_ : chunk->end();
    uword current = chunk->start();
    while (current < top && !has_sentinel_at(current)) {
      HeapObject* object = HeapObject::from_address(current);
      object->roots_do(program_, &heap_check);
      current += object->size(program_);
    }
  }
  for (auto chunk : from_) {
    for (uword p = chunk->start(); p < chunk->end(); p += WORD_SIZE) {
      *reinterpret_cast<uword*>(p) = static_cast<uword>(0xb1b1b1b1b1b1b1b1ULL);
    }
  }
}
#endif

void SandboxCopyingCollector::free_from_space() {
  while (Chunk* chunk = from_.remove_first()) {
    ObjectMemory::free_chunk(chunk);
  }
}

void SandboxCopyingCollector::collect() {
  ObjectHeap* roots = heap_->process_heap_;
  detach_from_space();

  roots->iterate_roots(this);
  scan();

  // Finalizers and weak maps, in the order of TwoSpaceHeap::do_scavenge and
  // perform_garbage_collection.
  weak_phase_ = true;
  roots->process_registered_callback_finalizers(this, this);
  roots->process_finalizer_queue(this, this);
  weak_phase_ = false;
  scan();
  roots->process_registered_vm_finalizers(this, this);
  scan();

#ifndef TOIT_FREERTOS
  verify_and_poison();
#endif
  free_from_space();

  if (space_->chunk_list_.is_empty()) {
    // Nothing survived: keep one page for the allocation window.
    Chunk* chunk = ObjectMemory::allocate_chunk(space_, TOIT_PAGE_SIZE);
    if (chunk == null) FATAL("sandbox copying GC: no page for the heap");
    to_pages_++;
    space_->chunk_list_.append(chunk);
    space_->top_ = chunk->start();
    space_->limit_ = chunk->end();
    write_sentinel_at(space_->top_);
  }
}

#ifndef TOIT_FREERTOS
// --- The in-place collector (prototype, hosts only) ----------------------------
//
// TOIT_SANDBOX_GC=inplace (untrusted processes) or inplace-all: the heap
// has the copying mode's shape (one space of pages, bump allocation), but a
// collection takes no page. It marks, computes new places, updates every
// reference and slides the live objects down, within the heap's own pages.
// The side tables are the VM's GC metadata (GcMetadata), which covers every
// heap page from boot: one mark bit per heap word and one word per line of
// 32 heap words (the "cumulative mark bits", here the line's base).
//   1. Mark: a fixed mark stack (TOIT_SANDBOX_GC_MARK_STACK entries, default
//      64). A push onto a full stack only marks and sets a flag; when the
//      stack is empty and the flag set, every marked object is scanned again
//      (a parse of the pages), until a scan ends without overflow. Only the
//      start word's bit is set. Roots, then the finalizer and weak-map passes
//      (is_alive, do_roots) as in the copying collector; nothing moves yet.
//   2. Places: a parse of the pages in list order. A marked object gets all
//      its words' bits set and the next place in the pages (next fit), with
//      the objects that start in one line always placed in one page, so that
//      an object's place is its line's base plus its line's marked words
//      before it (GcMetadata::get_destination's formula).
//   3. Update: every root, finalizer slot and reference field of a marked
//      object that points into the heap gets the referent's place.
//   4. Slide: the marked objects move to their places, in page order (a place
//      is never later in the page order than the object); pages after the
//      last one used are freed.
static inline uword raw_address(HeapObject* object) {
  return reinterpret_cast<uword>(object) - Object::HEAP_TAG;
}

class SandboxInPlaceCollector : public RootCallback, public LivenessOracle {
 public:
  static const word MAX_STACK = 4096;

  explicit SandboxInPlaceCollector(TwoSpaceHeap* heap)
      : program_(heap->program_)
      , heap_(heap)
      , space_(heap->new_space()) {
    const char* capacity = getenv("TOIT_SANDBOX_GC_MARK_STACK");
    stack_capacity_ = 64;
    if (capacity != null && atol(capacity) > 0) stack_capacity_ = Utils::min<word>(atol(capacity), MAX_STACK);
    const char* parse = getenv("TOIT_SANDBOX_GC_PARSE");
    parse_ = parse != null && parse[0] == '1';
    const char* compact = getenv("TOIT_SANDBOX_GC_COMPACT");
    jonkers_ = compact != null && strcmp(compact, "jonkers") == 0;
  }

  ~SandboxInPlaceCollector() {
    free(pages_);
    free(ranges_);
  }

  void collect();

  uword pages_before() const { return page_count_; }
  uword pages_after() const { return kept_; }
  uword live_bytes() const { return live_bytes_; }
  uword moved_bytes() const { return moved_bytes_; }
  uword line_loss() const { return line_loss_; }
  uword rescans() const { return rescans_; }
  uword max_depth() const { return max_depth_; }

  // RootCallback: marking.
  void do_roots(Object** roots, word length) override {
    for (word i = 0; i < length; i++) mark(roots[i]);
  }
  bool shrink_stacks() const override { return true; }
  bool skip_marking(HeapObject* object) const override {
    if (!object->has_active_finalizer()) return false;
    if (!is_instance(object)) return false;
    return object->class_id() == program_->map_class_id();
  }

  // LivenessOracle: objects outside the heap are alive; heap objects once
  // marked.
  bool is_alive(HeapObject* object) override {
    if (!in_heap(object)) return true;
    return is_marked(raw_address(object));
  }
  bool has_active_finalizer(HeapObject* object) override {
    return object->has_active_finalizer();
  }

  bool in_heap(HeapObject* object) const {
    uword address = reinterpret_cast<uword>(object);
    word low = 0;
    word high = page_count_;
    while (low < high) {
      word mid = (low + high) >> 1;
      if (address < ranges_[2 * mid]) {
        high = mid;
      } else if (address >= ranges_[2 * mid + 1]) {
        low = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  static bool is_marked(uword address) {
    return (*GcMetadata::mark_bits_for(address) & bit(address)) != 0;
  }

  // The place of a marked object (after phase 2).
  static uword place(uword address) {
    uint32 below = *GcMetadata::mark_bits_for(address) & (bit(address) - 1);
    return *GcMetadata::cumulative_mark_bits_for(address) + (Utils::popcount(below) << WORD_SHIFT);
  }

 private:
  struct Page {
    Chunk* chunk;
    uword new_top;
  };
  static const uword LINE = 32 * WORD_SIZE;

  Program* program_;
  TwoSpaceHeap* heap_;
  SemiSpace* space_;
  Page* pages_ = null;
  uword* ranges_ = null;  // Sorted [start, end) of the pages.
  word page_count_ = 0;
  word kept_ = 0;
  HeapObject* stack_[MAX_STACK];
  word stack_capacity_;
  word stack_size_ = 0;
  bool overflowed_ = false;
  uword live_bytes_ = 0;
  uword moved_bytes_ = 0;
  uword line_loss_ = 0;
  uword rescans_ = 0;
  uword max_depth_ = 0;
  bool parse_ = false;
  bool jonkers_ = false;
 public:
  // GcStats::instructions() after marking, places, update, slide.
  uint64 phase_instructions_[4] = {0, 0, 0, 0};
 private:

  static uint32 bit(uword address) { return 1u << ((address >> WORD_SHIFT) & 31); }

  void mark(Object* value) {
    if (!is_heap_object(value)) return;
    HeapObject* object = HeapObject::cast(value);
    if (!in_heap(object)) return;
    uword address = raw_address(object);
    uint32* bits = GcMetadata::mark_bits_for(address);
    uint32 mask = bit(address);
    if ((*bits & mask) != 0) return;
    *bits |= mask;
    if (stack_size_ < stack_capacity_) {
      stack_[stack_size_++] = object;
      if (static_cast<uword>(stack_size_) > max_depth_) max_depth_ = stack_size_;
    } else {
      overflowed_ = true;
    }
  }

  void empty_stack() {
    while (stack_size_ > 0) {
      HeapObject* object = stack_[--stack_size_];
      object->roots_do(program_, this);
    }
  }

  uword next_marked(uword current, uword end) const;
  uword threaded_size(uword address) const;
  void jonkers(bool second);
  void thread_roots();
  void drain();
  void set_up();
  void compute_places();
  void update();
  void slide();
  void verify_and_poison();
};

void SandboxInPlaceCollector::set_up() {
  space_->flush();
  for (auto chunk : space_->chunk_list_) {
    USE(chunk);
    page_count_++;
  }
  pages_ = static_cast<Page*>(malloc(page_count_ * sizeof(Page)));
  ranges_ = static_cast<uword*>(malloc(2 * page_count_ * sizeof(uword)));
  if (pages_ == null || ranges_ == null) FATAL("sandbox in-place GC: no memory for the page table");
  word i = 0;
  for (auto chunk : space_->chunk_list_) {
    pages_[i].chunk = chunk;
    pages_[i].new_top = chunk->start();
    GcMetadata::clear_mark_bits_for_chunk(chunk);
    word j = i;
    while (j > 0 && ranges_[2 * (j - 1)] > chunk->start()) {
      ranges_[2 * j] = ranges_[2 * (j - 1)];
      ranges_[2 * j + 1] = ranges_[2 * (j - 1) + 1];
      j--;
    }
    ranges_[2 * j] = chunk->start();
    ranges_[2 * j + 1] = chunk->end();
    i++;
  }
}

// The next marked object at or after `current` in the page that ends at
// `end`, or 0. With TOIT_SANDBOX_GC_PARSE=1 by stepping over the unmarked
// objects (their sizes from their headers); by default by searching the
// mark bits, which only marked objects have (start bits during marking,
// all their words' bits after phase 2).
uword SandboxInPlaceCollector::next_marked(uword current, uword end) const {
  if (parse_) {
    while (!has_sentinel_at(current)) {
      if (is_marked(current)) return current;
      current += HeapObject::from_address(current)->size(program_);
    }
    return 0;
  }
  while (current < end) {
    uint32 bits = *GcMetadata::mark_bits_for(current) >> ((current >> WORD_SHIFT) & 31);
    if (bits != 0) {
      uword result = current + (static_cast<uword>(Utils::ctz(bits)) << WORD_SHIFT);
      return result < end ? result : 0;
    }
    current = (current & ~(LINE - 1)) + LINE;
  }
  return 0;
}

void SandboxInPlaceCollector::drain() {
  while (true) {
    empty_stack();
    if (!overflowed_) return;
    overflowed_ = false;
    rescans_++;
    for (word i = 0; i < page_count_; i++) {
      Chunk* chunk = pages_[i].chunk;
      uword current = chunk->start();
      while ((current = next_marked(current, chunk->end())) != 0) {
        HeapObject* object = HeapObject::from_address(current);
        object->roots_do(program_, this);  // May shrink a stack.
        empty_stack();
        current += object->size(program_);
      }
    }
  }
}

void SandboxInPlaceCollector::compute_places() {
  word dp = 0;
  uword cursor = pages_[0].chunk->start();
  uword limit = pages_[0].chunk->usable_end();
  for (word p = 0; p < page_count_; p++) {
    Chunk* chunk = pages_[p].chunk;
    uword line = 1;          // No line yet (lines are aligned).
    uword line_place = 0;    // Place of the first marked object of `line`.
    uword current = chunk->start();
    while ((current = next_marked(current, chunk->end())) != 0) {
      HeapObject* object = HeapObject::from_address(current);
      uword size = object->size(program_);
      live_bytes_ += size;
      // All the object's words get their bit (the first already has it).
      uword rest = current + WORD_SIZE;
      uword words = (size >> WORD_SHIFT) - 1;
      if (words > 0) Utils::mark_bits(GcMetadata::mark_bits_for(rest), static_cast<int>((rest >> WORD_SHIFT) & 31), words);
      uword* base = GcMetadata::cumulative_mark_bits_for(current);
      uword l = current & ~(LINE - 1);
      if (l != line) {
        line = l;
        line_place = cursor;
        uint32 below = *GcMetadata::mark_bits_for(current) & (bit(current) - 1);
        *base = cursor - (Utils::popcount(below) << WORD_SHIFT);
      }
      if (cursor + size > limit) {
        // The objects of this line go to the next page.
        if (dp >= p) FATAL("sandbox in-place GC: place after the object");
        line_loss_ += cursor - line_place;  // What next fit per object would have kept here.
        pages_[dp].new_top = line_place;
        dp++;
        uword start = pages_[dp].chunk->start();
        cursor = start + (cursor - line_place);
        *base += start - line_place;
        line_place = start;
        limit = pages_[dp].chunk->usable_end();
      }
      ASSERT(place(current) == cursor);
      cursor += size;
      current += size;
    }
  }
  pages_[dp].new_top = cursor;
  kept_ = dp + 1;
}

// Phase 3: references to heap objects get their places.
class InPlaceUpdater : public RootCallback {
 public:
  InPlaceUpdater(SandboxInPlaceCollector* collector, bool check) : collector_(collector), check_(check) {}
  void do_roots(Object** roots, word length) override {
    for (word i = 0; i < length; i++) {
      Object* value = roots[i];
      if (!is_heap_object(value)) continue;
      HeapObject* object = HeapObject::cast(value);
      if (!collector_->in_heap(object)) continue;
      uword address = raw_address(object);
      if (check_ && !SandboxInPlaceCollector::is_marked(address)) {
        FATAL("sandbox in-place GC: slot %p points to an unmarked object %p", roots + i, value);
      }
      roots[i] = HeapObject::from_address(SandboxInPlaceCollector::place(address));
    }
  }

 private:
  SandboxInPlaceCollector* collector_;
  bool check_;
};

void SandboxInPlaceCollector::update() {
  InPlaceUpdater updater(this, gc_verify_enabled());
  ObjectHeap* roots = heap_->process_heap_;
  roots->iterate_roots(&updater);
  roots->iterate_finalization_roots(&updater);
  for (word i = 0; i < page_count_; i++) {
    Chunk* chunk = pages_[i].chunk;
    uword current = chunk->start();
    while ((current = next_marked(current, chunk->end())) != 0) {
      HeapObject* object = HeapObject::from_address(current);
      object->roots_do(program_, &updater);
      current += object->size(program_);
    }
  }
}

void SandboxInPlaceCollector::slide() {
  for (word i = 0; i < page_count_; i++) {
    Chunk* chunk = pages_[i].chunk;
    uword current = chunk->start();
    while ((current = next_marked(current, chunk->end())) != 0) {
      uword size = HeapObject::from_address(current)->size(program_);
      uword destination = place(current);
      if (destination != current) {
        memmove(reinterpret_cast<void*>(destination), reinterpret_cast<void*>(current), size);
        moved_bytes_ += size;
      }
      current += size;
    }
  }
}

// --- Jonkers threading (TOIT_SANDBOX_GC_COMPACT=jonkers): the comparison
// variant. No place table: every reference to a heap object is threaded
// into a chain through the object's header word (headers are smis, links
// are slot addresses with the heap tag), unthreaded when the object's place
// is known. Pass 1 (page order): an object's chain holds the roots and the
// references from objects before it; they get its place, then its own
// fields are threaded. Pass 2: the chains hold the references from objects
// after it (and from itself); they get its place, then it moves.
class InPlaceThreader : public RootCallback {
 public:
  explicit InPlaceThreader(SandboxInPlaceCollector* collector) : collector_(collector) {}
  void do_roots(Object** roots, word length) override {
    for (word i = 0; i < length; i++) {
      Object* value = roots[i];
      if (!is_heap_object(value)) continue;
      HeapObject* object = HeapObject::cast(value);
      if (!collector_->in_heap(object)) continue;
      uword* header = reinterpret_cast<uword*>(raw_address(object));
      roots[i] = reinterpret_cast<Object*>(*header);
      *header = reinterpret_cast<uword>(&roots[i]) | Object::HEAP_TAG;
    }
  }

 private:
  SandboxInPlaceCollector* collector_;
};

// The size of the object at `address` whose header may be threaded.
uword SandboxInPlaceCollector::threaded_size(uword address) const {
  uword* header = reinterpret_cast<uword*>(address);
  uword head = *header;
  uword value = head;
  while ((value & Object::HEAP_TAG) != 0) value = *reinterpret_cast<uword*>(value - Object::HEAP_TAG);
  *header = value;
  uword size = HeapObject::from_address(address)->size(program_);
  *header = head;
  return size;
}

// Every slot in the chain of the object at `address` gets `place`; the
// header gets its original value back.
static void unthread(uword address, uword place) {
  uword* header = reinterpret_cast<uword*>(address);
  uword value = *header;
  uword target = reinterpret_cast<uword>(HeapObject::from_address(place));
  while ((value & Object::HEAP_TAG) != 0) {
    uword* slot = reinterpret_cast<uword*>(value - Object::HEAP_TAG);
    value = *slot;
    *slot = target;
  }
  *header = value;
}

void SandboxInPlaceCollector::jonkers(bool second) {
  InPlaceThreader threader(this);
  word dp = 0;
  uword cursor = pages_[0].chunk->start();
  uword limit = pages_[0].chunk->usable_end();
  for (word p = 0; p < page_count_; p++) {
    Chunk* chunk = pages_[p].chunk;
    uword current = chunk->start();
    while ((current = next_marked(current, chunk->end())) != 0) {
      uword size = threaded_size(current);
      if (cursor + size > limit) {
        if (dp >= p) FATAL("sandbox in-place GC: place after the object");
        pages_[dp].new_top = cursor;
        dp++;
        cursor = pages_[dp].chunk->start();
        limit = pages_[dp].chunk->usable_end();
      }
      unthread(current, cursor);
      if (!second) {
        live_bytes_ += size;
        HeapObject::from_address(current)->roots_do(program_, &threader);
      } else if (cursor != current) {
        memmove(reinterpret_cast<void*>(cursor), reinterpret_cast<void*>(current), size);
        moved_bytes_ += size;
      }
      cursor += size;
      current += size;
    }
  }
  pages_[dp].new_top = cursor;
  kept_ = dp + 1;
}

void SandboxInPlaceCollector::thread_roots() {
  InPlaceThreader threader(this);
  ObjectHeap* roots = heap_->process_heap_;
  roots->iterate_roots(&threader);
  roots->iterate_finalization_roots(&threader);
}

void SandboxInPlaceCollector::verify_and_poison() {
  if (!gc_verify_enabled()) return;
  // The rest of each kept page and every freed page get the poison word.
  for (word i = 0; i < page_count_; i++) {
    Chunk* chunk = pages_[i].chunk;
    uword from = i < kept_ ? pages_[i].new_top + WORD_SIZE : chunk->start();
    for (uword p = from; p < chunk->end(); p += WORD_SIZE) {
      *reinterpret_cast<uword*>(p) = static_cast<uword>(0xb1b1b1b1b1b1b1b1ULL);
    }
  }
}

void SandboxInPlaceCollector::collect() {
  ObjectHeap* roots = heap_->process_heap_;
  set_up();

  roots->iterate_roots(this);
  drain();
  roots->process_registered_callback_finalizers(this, this);
  roots->process_finalizer_queue(this, this);
  drain();
  roots->process_registered_vm_finalizers(this, this);
  drain();

  if (GcStats::enabled()) phase_instructions_[0] = GcStats::instructions();
  if (jonkers_) {
    thread_roots();
    jonkers(false);
  } else {
    compute_places();
  }
  if (GcStats::enabled()) phase_instructions_[1] = GcStats::instructions();
  if (!jonkers_) update();
  if (GcStats::enabled()) phase_instructions_[2] = GcStats::instructions();
  if (jonkers_) {
    jonkers(true);
  } else {
    slide();
  }
  if (GcStats::enabled()) phase_instructions_[3] = GcStats::instructions();

  for (word i = 0; i < kept_; i++) write_sentinel_at(pages_[i].new_top);
  verify_and_poison();
  uword closed = 0;
  while (space_->chunk_list_.remove_first() != null) {}
  for (word i = 0; i < page_count_; i++) {
    Chunk* chunk = pages_[i].chunk;
    if (i < kept_) {
      GcMetadata::clear_mark_bits_for_chunk(chunk);
      space_->chunk_list_.append(chunk);
      if (i < kept_ - 1) closed += pages_[i].new_top - chunk->start();
    } else {
      GcMetadata::clear_mark_bits_for_chunk(chunk);  // The next owner finds them clear.
      ObjectMemory::free_chunk(chunk);
    }
  }
  Chunk* last = pages_[kept_ - 1].chunk;
  space_->top_ = pages_[kept_ - 1].new_top;
  space_->limit_ = last->end();
  heap_->copying_closed_used_ = closed;
}
#endif  // TOIT_FREERTOS

// --- TwoSpaceHeap's copying mode ----------------------------------------------

void TwoSpaceHeap::enable_copying_gc() {
  ASSERT(old_space_.is_empty());
  copying_ = true;
#ifndef TOIT_FREERTOS
  inplace_ = sandbox_inplace_gc_selected();
  const char* budget = getenv("TOIT_SANDBOX_GC_BUDGET");
  if (budget != null && atol(budget) > 0) copying_page_budget_ = static_cast<uword>(atol(budget));
  const char* stress = getenv("TOIT_SANDBOX_GC_STRESS");
  if (stress != null) {
    long window = atol(stress);
    if (window > 0) {
      // The window is first cut after the first collection: the heap is
      // still being set up (the first task) when this is called.
      copying_stress_window_ = Utils::round_up(static_cast<uword>(window), WORD_SIZE);
    }
  }
#endif
}

void TwoSpaceHeap::copying_cut_window() {
  if (copying_stress_window_ == 0 || semi_space_.chunk_list_.is_empty()) return;
  uword end = semi_space_.chunk_list_.last()->end();
  uword limit = semi_space_.top_ + copying_stress_window_;
  semi_space_.limit_ = (limit < end && limit > semi_space_.top_) ? limit : end;
}

uword TwoSpaceHeap::copying_allocate_slow(uword size) {
  if (size + SENTINEL_SIZE >= static_cast<uword>(TOIT_PAGE_SIZE)) return 0;
  if (copying_stress_window_ != 0 && !semi_space_.chunk_list_.is_empty()) {
    // Test mode: outside a retry every allocation beyond the window asks
    // for a collection; in a retry the window moves on in the same page.
    if (!process_heap_->retrying_primitive()) return 0;
    Chunk* last = semi_space_.chunk_list_.last();
    if (last->end() - semi_space_.top_ > size) {
      semi_space_.limit_ = last->end();
      uword result = semi_space_.try_allocate(size);
      copying_cut_window();
      return result;
    }
  }
  if (copying_page_budget_ != 0 && copying_pages_since_gc_ >= copying_page_budget_ &&
      !process_heap_->retrying_primitive()) {
    return 0;  // Collect before growing further.
  }
  word room = max_external_allocation();
  if (room < TOIT_PAGE_SIZE) return 0;  // Over the limit (-1) or too close: collect.
  if (!semi_space_.chunk_list_.is_empty()) {
    semi_space_.flush();
    copying_closed_used_ += semi_space_.top_ - semi_space_.chunk_list_.last()->start();
  }
  Chunk* chunk = ObjectMemory::allocate_chunk(&semi_space_, TOIT_PAGE_SIZE);
  if (chunk == null) {
    report_malloc_failed();
    return 0;
  }
  copying_pages_since_gc_++;
  semi_space_.chunk_list_.append(chunk);
  semi_space_.top_ = chunk->start();
  semi_space_.limit_ = chunk->end();
  write_sentinel_at(semi_space_.top_);
  if (stats_ != null) stats_->note_pages(this->size() / TOIT_PAGE_SIZE);
  uword result = semi_space_.try_allocate(size);
  copying_cut_window();
  return result;
}

// --- Statistics ----------------------------------------------------------------

bool GcStats::enabled() {
#ifdef TOIT_FREERTOS
  return false;
#else
  static int enabled = -1;
  if (enabled < 0) {
    const char* value = getenv("TOIT_GC_STATS");
    enabled = (value != null && value[0] != '\0' && strcmp(value, "0") != 0) ? 1 : 0;
  }
  return enabled == 1;
#endif
}

uint64 GcStats::instructions() {
#if defined(TOIT_LINUX)
  static thread_local int fd = -2;
  if (fd == -2) {
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.type = PERF_TYPE_HARDWARE;
    attr.size = sizeof(attr);
    attr.config = PERF_COUNT_HW_INSTRUCTIONS;
    attr.exclude_kernel = 1;
    attr.exclude_hv = 1;
    fd = static_cast<int>(syscall(__NR_perf_event_open, &attr, 0, -1, -1, 0));
  }
  if (fd < 0) return 0;
  uint64 count = 0;
  if (read(fd, &count, sizeof(count)) != sizeof(count)) return 0;
  return count;
#else
  return 0;
#endif
}

void GcStats::record_inplace(uword pages_before, uword pages_after, uword live, uword moved, uword rescans, uword depth) {
  inplace_gcs++;
  live_bytes += live;
  if (live > max_live_bytes) max_live_bytes = live;
  moved_bytes += moved;
  mark_rescans += rescans;
  if (depth > max_mark_depth) max_mark_depth = depth;
  if (pages_before > max_from_pages) max_from_pages = pages_before;
  if (pages_after > max_kept_pages) max_kept_pages = pages_after;
  note_pages(pages_before);
}

void GcStats::record_copying(uword from_pages, uword to_pages, uword copied, uword waste) {
  copying_gcs++;
  copied_bytes += copied;
  if (copied > max_copied_bytes) max_copied_bytes = copied;
  if (to_pages > max_to_pages) max_to_pages = to_pages;
  if (from_pages > max_from_pages) max_from_pages = from_pages;
  if (from_pages > 0) {
    int ratio = static_cast<int>(to_pages * 1000 / from_pages);
    if (ratio > max_to_over_from) max_to_over_from = ratio;
  }
  to_space_waste += waste;
  note_pages(from_pages + to_pages);
}

// --- Heap dumps for the differential test of the proved collector -----------

#ifndef TOIT_FREERTOS
// With TOIT_GC_DUMP=DIR, every copying collection writes the heap before it
// (DIR/gc-OSPID-PID-N-before.bin) and after it (-after.bin), up to
// TOIT_GC_DUMP_MAX (default 50) collections per process: the pages, the
// root values (ObjectHeap::iterate_roots) and what is needed to read the
// objects (word size, page bytes, the stack array word, the null object's
// address, the class bits). verified/gc/tests/difftest.rs runs the proved
// collector on each "before" and compares its result with "after" up to
// renumbering. Host only, test only.

// Writes each root value as it is visited; the count goes before them.
class RootRecorder : public RootCallback {
 public:
  explicit RootRecorder(FILE* file) : file_(file) {
    count_position_ = ftell(file_);
    uint64 zero = 0;
    fwrite(&zero, sizeof(zero), 1, file_);
  }
  void do_roots(Object** roots, word length) override {
    for (word i = 0; i < length; i++) {
      uint64 v64 = reinterpret_cast<uword>(roots[i]);
      fwrite(&v64, sizeof(v64), 1, file_);
      count_++;
    }
  }
  void write() {
    long end = ftell(file_);
    fseek(file_, count_position_, SEEK_SET);
    fwrite(&count_, sizeof(count_), 1, file_);
    fseek(file_, end, SEEK_SET);
  }

 private:
  FILE* file_;
  long count_position_ = 0;
  uint64 count_ = 0;
};

static void write_u64(FILE* file, uint64 v) {
  fwrite(&v, sizeof(v), 1, file);
}

static int os_pid() {
#if defined(TOIT_LINUX)
  return static_cast<int>(getpid());
#else
  return 0;
#endif
}

static int gc_dump_max() {
  const char* max = getenv("TOIT_GC_DUMP_MAX");
  return max != null ? atoi(max) : 50;
}

void TwoSpaceHeap::dump_copying_heap(const char* phase) {
  const char* dir = getenv("TOIT_GC_DUMP");
  if (dir == null || copying_dump_count_ >= gc_dump_max()) return;
  Process* owner = process();
  char path[512];
  snprintf(path, sizeof(path), "%s/gc-%d-%d-%d-%s.bin", dir, os_pid(),
           owner != null ? owner->id() : -1, copying_dump_count_, phase);
  FILE* file = fopen(path, "wb");
  if (file == null) return;
  semi_space_.flush();
  write_u64(file, 0x31444347544f4954ULL);  // "TOITGCD1".
  write_u64(file, WORD_SIZE);
  write_u64(file, Stack::v2_array_word());
  write_u64(file, reinterpret_cast<uword>(program_->null_object()));
  word classes = program_->class_bits.length();
  write_u64(file, classes);
  for (word i = 0; i < classes; i++) write_u64(file, static_cast<uint16>(program_->class_bits[i]));
  uint64 pages = 0;
  for (auto chunk : semi_space_.chunk_list_) {
    USE(chunk);
    pages++;
  }
  write_u64(file, pages);
  for (auto chunk : semi_space_.chunk_list_) {
    bool last = chunk == semi_space_.chunk_list_.last();
    uword used = last ? semi_space_.top_ - chunk->start() : chunk->end() - chunk->start();
    write_u64(file, chunk->start());
    write_u64(file, chunk->end() - chunk->start());
    write_u64(file, used);
    fwrite(reinterpret_cast<void*>(chunk->start()), 1, chunk->end() - chunk->start(), file);
  }
  RootRecorder roots(file);
  process_heap_->iterate_roots(&roots);
  roots.write();
  // The finalizer nodes: list, kind, node, key, lambda (null for VM nodes).
  long count_position = ftell(file);
  uint64 zero = 0;
  fwrite(&zero, sizeof(zero), 1, file);
  struct NodeWriter { FILE* file; uint64 count; } writer = { file, 0 };
  process_heap_->dump_finalizer_nodes(&writer, [](void* context, int list, int kind, void* node, Object* key, Object* lambda) {
    auto w = static_cast<NodeWriter*>(context);
    write_u64(w->file, list);
    write_u64(w->file, kind);
    write_u64(w->file, reinterpret_cast<uword>(node));
    write_u64(w->file, reinterpret_cast<uword>(key));
    write_u64(w->file, reinterpret_cast<uword>(lambda));
    w->count++;
  });
  long end = ftell(file);
  fseek(file, count_position, SEEK_SET);
  write_u64(file, writer.count);
  fseek(file, end, SEEK_SET);
  // The room a shrunk stack keeps above its records (Stack::shrink_v2_for_gc):
  // the proved collector's Ctx::smin.
  word height = program_->global_max_stack_height();
  uint64 smin = (program_->is_format2() && height >= 0)
      ? static_cast<uint64>(2 * height + RESERVED_STACK_FOR_CALLS + Stack::V2_FRAME_WORDS + Stack::V2_STACK_RESERVE)
      : static_cast<uint64>(UINTPTR_MAX);
  write_u64(file, smin);
  // The class ids of maps, lists and tombstones (weak maps).
  write_u64(file, Smi::value(program_->map_class_id()));
  write_u64(file, Smi::value(program_->list_class_id()));
  write_u64(file, Smi::value(program_->tombstone_class_id()));
  fclose(file);
}
#endif

GcType TwoSpaceHeap::collect(bool try_hard) {
  if (stats_ == null && GcStats::enabled()) stats_ = _new GcStats();
  bool stats = stats_ != null;
  uint64 instructions = 0;
  uint64 start_us = 0;
  if (stats) {
    Process* owner = process();
    if (owner != null) {
      stats_->pid = owner->id();
      stats_->untrusted = owner->policy()->is_untrusted();
    }
    stats_->copying = copying_;
#ifndef TOIT_FREERTOS
    stats_->inplace = inplace_;
#endif
    stats_->note_pages(size() / TOIT_PAGE_SIZE);
    start_us = OS::get_monotonic_time();
    instructions = GcStats::instructions();
  }
  GcType type;
  if (copying_) {
    malloc_failed_ = false;
    total_bytes_allocated_.fetch_add(new_space_used(), std::memory_order_relaxed);
#ifndef TOIT_FREERTOS
    dump_copying_heap("before");
    if (inplace_) {
      SandboxInPlaceCollector collector(this);
      collector.collect();
      dump_copying_heap("after");
      if (getenv("TOIT_GC_DUMP") != null) copying_dump_count_++;
      copying_pages_since_gc_ = 0;
      copying_cut_window();
      total_bytes_allocated_.fetch_sub(new_space_used(), std::memory_order_relaxed);
      if (stats) {
        stats_->record_inplace(collector.pages_before(), collector.pages_after(), collector.live_bytes(),
                               collector.moved_bytes(), collector.rescans(), collector.max_depth());
        stats_->phase_instructions[0] += collector.phase_instructions_[0] - instructions;
        stats_->line_loss_bytes += collector.line_loss();
        if (collector.line_loss() > stats_->max_line_loss_bytes) stats_->max_line_loss_bytes = collector.line_loss();
        for (int i = 1; i < 4; i++) stats_->phase_instructions[i] += collector.phase_instructions_[i] - collector.phase_instructions_[i - 1];
        if (Flags::tracegc) {
          printf("[sandbox in-place gc %d: %zu -> %zu pages, live %zu, moved %zu, rescans %zu, depth %zu]\n",
                 stats_->pid, static_cast<size_t>(collector.pages_before()),
                 static_cast<size_t>(collector.pages_after()),
                 static_cast<size_t>(collector.live_bytes()), static_cast<size_t>(collector.moved_bytes()),
                 static_cast<size_t>(collector.rescans()), static_cast<size_t>(collector.max_depth()));
        }
      }
      type = FULL_GC;
      goto done;
    }
#endif
    SandboxCopyingCollector collector(this);
    collector.collect();
#ifndef TOIT_FREERTOS
    dump_copying_heap("after");
    if (getenv("TOIT_GC_DUMP") != null) copying_dump_count_++;
#endif
    copying_pages_since_gc_ = 0;
    copying_cut_window();
    total_bytes_allocated_.fetch_sub(new_space_used(), std::memory_order_relaxed);
    if (stats) {
      stats_->record_copying(collector.from_pages(), collector.to_pages(),
                            collector.copied_bytes(), collector.waste());
      if (Flags::tracegc) {
        printf("[sandbox gc %d: %zu -> %zu pages, copied %zu, waste %zu, external %zu, limit %zd]\n",
               stats_->pid, static_cast<size_t>(collector.from_pages()),
               static_cast<size_t>(collector.to_pages()),
               static_cast<size_t>(collector.copied_bytes()), static_cast<size_t>(collector.waste()),
               static_cast<size_t>(process_heap_->external_memory()),
               static_cast<ssize_t>(process_heap_->limit()));
      }
    }
    type = FULL_GC;
  } else {
    type = collect_new_space(try_hard);
    if (stats) {
      // The scavenge used the spare chunk (one page) next to from-space.
      stats_->note_pages(size() / TOIT_PAGE_SIZE + 1);
    }
  }
#ifndef TOIT_FREERTOS
done:
#endif
  if (stats) {
    uint64 spent = GcStats::instructions() - instructions;
    uint64 us = OS::get_monotonic_time() - start_us;
    stats_->collections++;
    stats_->gc_instructions += spent;
    if (spent > stats_->max_gc_instructions) stats_->max_gc_instructions = spent;
    stats_->gc_us += us;
    if (us > stats_->max_gc_us) stats_->max_gc_us = us;
  }
  return type;
}

void GcStats::print(TwoSpaceHeap* heap) {
  if (!enabled() || pid < 0) return;
  printf("GCSTATS pid=%d untrusted=%d mode=%s collections=%zu scavenges=%zu full=%zu compacting=%zu copying=%zu"
         " survivors=%llu max_survivors=%zu promoted=%llu copied=%llu max_copied=%zu"
         " gc_instr=%llu max_gc_instr=%llu gc_us=%llu max_gc_us=%llu peak_pages=%zu"
         " max_from_pages=%zu max_to_pages=%zu max_to_over_from=%d to_waste=%llu allocated=%llu full_instr=%llu full_live=%llu full_space=%llu"
         " inplace=%zu live=%llu max_live=%zu moved=%llu rescans=%zu max_mark_depth=%zu max_kept_pages=%zu phase_instr=%llu,%llu,%llu,%llu line_loss=%llu max_line_loss=%zu\n",
         pid, untrusted ? 1 : 0, inplace ? "inplace" : copying ? "copying" : "generational",
         static_cast<size_t>(collections), static_cast<size_t>(scavenges),
         static_cast<size_t>(full_gcs), static_cast<size_t>(compacting_gcs),
         static_cast<size_t>(copying_gcs),
         static_cast<unsigned long long>(survivor_bytes), static_cast<size_t>(max_survivor_bytes),
         static_cast<unsigned long long>(promoted_bytes),
         static_cast<unsigned long long>(copied_bytes), static_cast<size_t>(max_copied_bytes),
         static_cast<unsigned long long>(gc_instructions),
         static_cast<unsigned long long>(max_gc_instructions),
         static_cast<unsigned long long>(gc_us), static_cast<unsigned long long>(max_gc_us),
         static_cast<size_t>(peak_pages), static_cast<size_t>(max_from_pages),
         static_cast<size_t>(max_to_pages), max_to_over_from,
         static_cast<unsigned long long>(to_space_waste),
         static_cast<unsigned long long>(heap->total_bytes_allocated()),
         static_cast<unsigned long long>(full_instructions),
         static_cast<unsigned long long>(full_live_bytes),
         static_cast<unsigned long long>(full_space_bytes),
         static_cast<size_t>(inplace_gcs), static_cast<unsigned long long>(live_bytes),
         static_cast<size_t>(max_live_bytes), static_cast<unsigned long long>(moved_bytes),
         static_cast<size_t>(mark_rescans), static_cast<size_t>(max_mark_depth),
         static_cast<size_t>(max_kept_pages),
         static_cast<unsigned long long>(phase_instructions[0]), static_cast<unsigned long long>(phase_instructions[1]),
         static_cast<unsigned long long>(phase_instructions[2]), static_cast<unsigned long long>(phase_instructions[3]),
         static_cast<unsigned long long>(line_loss_bytes), static_cast<size_t>(max_line_loss_bytes));
  fflush(stdout);
}

}  // namespace toit
