// Copyright (c) 2022, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#pragma once

#include "../../top.h"

#include <atomic>

#include "../../linked.h"
#include "../../heap_roots.h"
#include "../../objects.h"
#include "../../os.h"
#include "../../utils.h"

namespace toit {

class Chunk;
class FreeList;
class ScavengeVisitor;
class HeapObject;
class HeapObjectVisitor;
class MarkingStack;
class Object;
class OldSpace;
class RootCallback;
class Program;
class PromotedTrack;
class Smi;
class Space;
class TwoSpaceHeap;

static const int SENTINEL_SIZE = sizeof(void*);

// In oldspace, the sentinel marks the end of each chunk, and never moves or is
// overwritten.
static inline Object* chunk_end_sentinel() {
  return reinterpret_cast<Object*>(0);
}

static inline bool has_sentinel_at(uword address) {
  return *reinterpret_cast<Object**>(address) == chunk_end_sentinel();
}

enum PageType {
  UNKNOWN_SPACE_PAGE,  // Probably a metadata page.
  OLD_SPACE_PAGE,
  NEW_SPACE_PAGE
};

typedef DoubleLinkedList<Chunk> ChunkList;
typedef DoubleLinkedList<Chunk>::Iterator ChunkListIterator;

// A chunk represents a block of memory provided by ObjectMemory.
class Chunk : public ChunkList::Element {
 public:
  // The space owning this chunk.
  Space* owner() const { return owner_; }
  void set_owner(Space* value);

  // Returns the first address in this chunk.
  uword start() const { return start_; }

  // Returns the first address past this chunk.
  uword end() const { return end_; }

  uword usable_end() const { return end_ - SENTINEL_SIZE; }

  uword compaction_top() { return compaction_top_; }

  void set_compaction_top(uword top) { compaction_top_ = top; }

  // Returns the size of this chunk in bytes.
  uword size() const { return end_ - start_; }

  // Test for inclusion.
  bool includes(uword address) {
    return (address >= start_) && (address < end_);
  }

  void set_scavenge_pointer(uword p) {
    ASSERT(p >= start_);
    ASSERT(p <= end_);
    scavenge_pointer_ = p;
  }
  uword scavenge_pointer() const { return scavenge_pointer_; }

  void initialize_metadata() const;

#ifdef TOIT_DEBUG
  // Fill the space with garbage.
  void scramble();

  // Support for the heap find method, used when debugging.
  void find(uword word, const char* name);
#endif

 private:
  ~Chunk();  // Use ObjectMemory::free_chunk().

  Space* owner_;
  const uword start_;
  const uword end_;
  uword scavenge_pointer_;
  uword compaction_top_;

  Chunk(Space* owner, uword start, uword size);

  friend class ObjectMemory;
};

// Abstract base class for visiting all objects in a space.
class HeapObjectVisitor {
 public:
  explicit HeapObjectVisitor(Program* program) : program_(program) {}
  virtual ~HeapObjectVisitor() {}
  // Visit the heap object. Must return the size of the heap
  // object.
  virtual uword visit(HeapObject* object) = 0;
  // Notification that the end of a chunk has been reached. A heap
  // object visitor visits all heap objects in a chunk in order
  // calling visit on each of them. When it reaches the end of the
  // chunk it calls chunk_end.
  virtual void chunk_end(Chunk* chunk, uword end) {}
  // Notification that we are about to iterate over a chunk.
  virtual void chunk_start(Chunk* chunk) {}

 protected:
  Program* program_;
};

class LivenessOracle {
 public:
  virtual bool is_alive(HeapObject* object) = 0;
};

// Space is a chain of chunks. It supports allocation and traversal.
class Space : public LivenessOracle {
 public:
  static const uword DEFAULT_MINIMUM_CHUNK_SIZE = TOIT_PAGE_SIZE;
#ifdef TOIT_FREERTOS
  static const uword DEFAULT_MAXIMUM_CHUNK_SIZE = TOIT_PAGE_SIZE;
#else
  static const uword DEFAULT_MAXIMUM_CHUNK_SIZE = 256 * KB;
#endif

  virtual ~Space();

  enum Resizing { CAN_RESIZE, CANNOT_RESIZE };

  // Returns the total size of allocated objects.
  virtual uword used() const = 0;

  // flush will make the current chunk consistent for iteration.
  virtual void flush() = 0;
  virtual bool is_flushed() = 0;

  // Used for weak processing.  Can only be called:
  // 1) For copying collections: right after copying but before you delete the
  //    from-space.  Only for heap objects originally in the from-space.
  // 2) For mark-sweep collections: Between marking and sweeping.  Only makes
  //    sense for the mark-sweep space, since objects in the semispace will
  //    survive regardless of their mark bit.
  virtual bool is_alive(HeapObject* old_location) = 0;

  // Do not call if the object died in the current GC.  Used for weak
  // processing.
  virtual HeapObject* new_location(HeapObject* old_location) = 0;

  // Returns the total size of allocated chunks.
  uword size() const;

  // Iterate over all objects in this space.
  void iterate_objects(HeapObjectVisitor* visitor);

  // Iterate all the objects that are grey, after a mark stack overflow.
  void iterate_overflowed_objects(RootCallback* visitor, MarkingStack* stack);

  // Returns true if the address is inside this space.  Not particularly fast.
  // See GcMetadata::PageType for a faster possibility.
  bool includes(uword address);

  void clear_mark_bits();

  bool is_empty() const { return chunk_list_.is_empty(); }

  ChunkListIterator chunk_list_begin() { return chunk_list_.begin(); }
  ChunkListIterator chunk_list_end() { return chunk_list_.end(); }

  static uword get_default_chunk_size(uword heap_size) {
    // We return a value between DEFAULT_MINIMUM_CHUNK_SIZE and
    // DEFAULT_MAXIMUM_CHUNK_SIZE - and try to keep the chunks smaller than 20% of
    // the heap.
    return Utils::min(
        Utils::max(DEFAULT_MINIMUM_CHUNK_SIZE, heap_size / 5),
        DEFAULT_MAXIMUM_CHUNK_SIZE);
  }

  // Obtain the offset of [object] from the start of the chunk. We assume
  // there is exactly one chunk in this space and [object] lies within it.
  word offset_of(HeapObject* object);
  HeapObject* object_at_offset(word offset);

#ifdef TOIT_DEBUG
  void find(uword word, const char* name);
#endif

  uword single_chunk_start() {
    ASSERT(chunk_list_.first() == chunk_list_.last());
    return chunk_list_.first()->start();
  }

  uword single_chunk_size() {
    ASSERT(chunk_list_.first() == chunk_list_.last());
    return chunk_list_.first()->size();
  }

  bool is_in_single_chunk(HeapObject* object) {
    ASSERT(chunk_list_.first() == chunk_list_.last());
    return reinterpret_cast<uword>(object) - single_chunk_start() < single_chunk_size();
  }

  Chunk* chunk() {
    ASSERT(chunk_list_.first() == chunk_list_.last());
    return chunk_list_.first();
  }

  Chunk* remove_chunk() {
    return chunk_list_.remove_first();
  }

  PageType page_type() { return page_type_; }

  inline void swap(Space& other) {
    using std::swap;
    swap(program_, other.program_);
    swap(chunk_list_, other.chunk_list_);
    swap(top_, other.top_);
    swap(limit_, other.limit_);
    swap(page_type_, other.page_type_);
  }

  void validate_before_mark_sweep(PageType page_type, bool object_starts_should_be_clear);

 protected:
  Space(Program* program, Resizing resizeable, PageType page_type);

  friend class Chunk;
  friend class TwoSpaceHeap;

  virtual void append(Chunk* chunk);

  void free_all_chunks();

  uword top() const { return top_; }

  Program* program_ = null;
  ChunkList chunk_list_;
  uword top_ = 0;               // Allocation top in current chunk.
  uword limit_ = 0;             // Allocation limit in current chunk.
  PageType page_type_;
};

inline void swap(Space& a, Space& b) {
  a.swap(b);
}

class SemiSpace : public Space {
 public:
  SemiSpace(Program* program, Chunk* chunk);

  // Returns the total size of allocated objects.
  virtual uword used() const;

  virtual bool is_alive(HeapObject* old_location);
  virtual HeapObject* new_location(HeapObject* old_location);

  // flush will make the current chunk consistent for iteration.
  virtual void flush();

  virtual bool is_flushed();

  void trigger_gc_soon() { limit_ = top_ + SENTINEL_SIZE; }

  // Allocate raw object. Returns 0 if a garbage collection is needed
  // and causes a fatal error if no garbage collection is needed and
  // there is no room to allocate the object.
  uword allocate(uword size);

  // For the mutable heap.
  void start_scavenge();
  bool complete_scavenge(ScavengeVisitor* visitor);

  void update_base_and_limit(Chunk* chunk, uword top);

  virtual void append(Chunk* chunk);

  inline void swap(SemiSpace& other) {
    static_cast<Space&>(*this).swap(static_cast<Space&>(other));
  }

  void validate();

 private:
  Chunk* allocate_and_use_chunk(uword size);

  uword allocate_in_new_chunk(uword size);
};

inline void swap(SemiSpace& a, SemiSpace& b) {
  a.swap(b);
}

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
    int bucket = WORD_BITS - Utils::clz(free_size) - 1;
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

class OldSpace : public Space {
 public:
  OldSpace(Program* program, TwoSpaceHeap* heap);

  virtual ~OldSpace();

  virtual bool is_alive(HeapObject* old_location);

  virtual HeapObject* new_location(HeapObject* old_location);

  virtual uword used() const;

  // flush will make the current chunk consistent for iteration.
  virtual void flush();

  virtual bool is_flushed() { return top_ == 0; }

  // Allocate raw object. Returns 0 if a garbage collection is needed
  // and causes a fatal error if no garbage collection is needed and
  // there is no room to allocate the object.
  uword allocate(uword size);

  FreeList* free_list() { return &free_list_; }

  void clear_free_list();
  void mark_chunk_ends_free();
  void zap_object_starts();

  // Find pointers to young-space.
  void visit_remembered_set(ScavengeVisitor* visitor);

  // Until the write barrier works.
  void rebuild_remembered_set();

  // For the objects promoted to the old space during scavenge.
  void start_scavenge();
  bool complete_scavenge(ScavengeVisitor* visitor);
  void end_scavenge();

  void start_tracking_allocations();
  void end_tracking_allocations();
  void unlink_promoted_track();

  void use_whole_chunk(Chunk* chunk);

  word compute_compaction_destinations();

  void validate();

  void set_compacting(bool value) { compacting_ = value; }

  void set_used_after_last_gc(uword used) { used_after_last_gc_ = used; }

  uword sweep();

  // Tells whether garbage collection is needed.  Only to be called when
  // bump allocation has failed, or on old space after a new-space GC.
  bool needs_garbage_collection() {
    if (tracking_allocations_) return false;  // We are already in a scavenge.
    return used_ > 0 && promotion_failed_;
  }

  uword minimum_progress();
  void report_new_space_progress(uword bytes_collected);
  void set_used(uword used) { used_ = used; }
  void set_promotion_failed(bool value) { promotion_failed_ = value; }

 private:
  uword allocate_from_free_list(uword size);
  uword allocate_in_new_chunk(uword size);
  Chunk* allocate_and_use_chunk(uword size);
  void validate_sweep(Chunk* chunk);

  TwoSpaceHeap* heap_;
  FreeList free_list_;  // Free list structure.
  bool tracking_allocations_ = false;
  PromotedTrack* promoted_track_ = null;
  bool compacting_ = true;

  // Actually new space garbage found since last compacting GC. Used to
  // evaluate whether we are out of memory.
  uword new_space_garbage_found_since_last_gc_ = 0;
  int successive_pointless_gcs_ = 0;
  uword used_after_last_gc_ = 0;
  uword used_ = 0;               // Allocated bytes.
  // Record whether a promotion failed during a scavenge, so we can save time
  // by not trying to promote later objects - they are put in the other
  // semispace even though they are old enough for promotion.  We also use this
  // to trigger an old-space GC early.
  bool promotion_failed_ = false;
};

// ObjectMemory controls all memory used by object heaps.
class ObjectMemory {
 public:
  // Allocate a new chunk for a given space. All chunk sizes are
  // rounded up the page size and the allocated memory is aligned
  // to a page boundary.
  static Chunk* allocate_chunk(Space* space, uword size);

  // Release the chunk.
  static void free_chunk(Chunk* chunk);

  // Set up and tear-down support.
  static void set_up();
  static void tear_down();

  static uword allocated() { return allocated_; }

  static inline Mutex* spare_chunk_mutex() { return spare_chunk_mutex_; }

  static inline Chunk* spare_chunk(Locker& locker) { return spare_chunk_; }
  static inline void set_spare_chunk(Locker& locker, Chunk* spare_chunk) { spare_chunk_ = spare_chunk; }

 private:
  static Chunk* allocate_chunk_helper(Space* space, uword size, void* memory);

  static std::atomic<uword> allocated_;

  static Chunk* spare_chunk_;
  static Mutex* spare_chunk_mutex_;
};

}  // namespace toit
