// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#ifndef SRC_VM_OBJECT_MEMORY_H_
#define SRC_VM_OBJECT_MEMORY_H_

#include "src/shared/globals.h"
#include "src/shared/platform.h"
#include "src/shared/utils.h"
#include "src/vm/double_list.h"
#include "src/vm/weak_pointer.h"

namespace dartino {

class Chunk;
class FreeList;
class GenerationalScavengeVisitor;
class Heap;
class HeapObject;
class HeapObjectVisitor;
class MarkingStack;
class Object;
class OldSpace;
class PointerVisitor;
class ProgramHeapRelocator;
class PromotedTrack;
class Smi;
class Space;
class TwoSpaceHeap;

static const int kSentinelSize = sizeof(void*);

// In oldspace, the sentinel marks the end of each chunk, and never moves or is
// overwritten.
static inline Object* chunk_end_sentinel() {
  return reinterpret_cast<Object*>(0);
}

static inline bool HasSentinelAt(uword address) {
  return *reinterpret_cast<Object**>(address) == chunk_end_sentinel();
}

enum PageType {
  kUnknownSpacePage,  // Probably a program space page.
  kOldSpacePage,
  kNewSpacePage
};

typedef DoubleList<Chunk> ChunkList;
typedef DoubleList<Chunk>::Iterator<Chunk> ChunkListIterator;

// A chunk represents a block of memory provided by ObjectMemory.
class Chunk : public ChunkList::Entry {
 public:
  // The space owning this chunk.
  Space* owner() const { return owner_; }

  // Returns the first address in this chunk.
  uword start() const { return start_; }

  // Returns the first address past this chunk.
  uword end() const { return end_; }

  uword usable_end() const { return end_ - kSentinelSize; }

  uword compaction_top() { return compaction_top_; }

  void set_compaction_top(uword top) { compaction_top_ = top; }

  // Returns the size of this chunk in bytes.
  uword size() const { return end_ - start_; }

  // Is the chunk externally allocated by the embedder.
  bool is_external() const { return external_; }

  // Test for inclusion.
  bool Includes(uword address) {
    return (address >= start_) && (address < end_);
  }

  void set_scavenge_pointer(uword p) {
    ASSERT(p >= start_);
    ASSERT(p <= end_);
    scavenge_pointer_ = p;
  }
  uword scavenge_pointer() const { return scavenge_pointer_; }

#ifdef DEBUG
  // Fill the space with garbage.
  void Scramble();

  // Support for the heap Find method, used when debugging.
  void Find(uword word, const char* name);
#endif

 private:
  Space* owner_;
  const uword start_;
  const uword end_;
  const bool external_;
  uword scavenge_pointer_;
  uword compaction_top_;

  Chunk(Space* owner, uword start, uword size, bool external = false);
  ~Chunk();

  void set_owner(Space* value) { owner_ = value; }

  friend class ObjectMemory;
  friend class SemiSpace;
  friend class Space;
};

// Space is a chain of chunks. It supports allocation and traversal.
class Space {
 public:
  static const uword kDefaultMinimumChunkSize = Platform::kPageSize;
  static const uword kDefaultMaximumChunkSize = 256 * KB;

  virtual ~Space();

  enum Resizing { kCanResize, kCannotResize };

  // Returns the total size of allocated objects.
  virtual uword Used() = 0;

  // Flush will make the current chunk consistent for iteration.
  virtual void Flush() = 0;

  // Used for weak processing.  Can only be called:
  // 1) For copying collections: right after copying but before you delete the
  //    from-space.  Only for heap objects originally in the from-space.
  // 2) For mark-sweep collections: Between marking and sweeping.  Only makes
  //    sense for the mark-sweep space, since objects in the semispace will
  //    survive regardless of their mark bit.
  virtual bool IsAlive(HeapObject* old_location) = 0;

  // Do not call if the object died in the current GC.  Used for weak
  // processing.
  virtual HeapObject* NewLocation(HeapObject* old_location) = 0;

  // Instance transformation leaves garbage in the heap so we rebuild the
  // space after transformations.
  virtual void RebuildAfterTransformations() = 0;

  void set_used(uword used) { used_ = used; }

  // Returns the total size of allocated chunks.
  uword Size();

  // Iterate over all objects in this space.
  void IterateObjects(HeapObjectVisitor* visitor);

  // Iterate all the objects that are grey, after a mark stack overflow.
  void IterateOverflowedObjects(PointerVisitor* visitor, MarkingStack* stack);

  // Schema change support.
  void CompleteTransformations(PointerVisitor* visitor);

  // Returns true if the address is inside this space.  Not particularly fast.
  // See GCMetadata::PageType for a faster possibility.
  bool Includes(uword address);

  // Adjust the allocation budget based on the current heap size.
  void AdjustAllocationBudget(uword used_outside_space);

  void IncreaseAllocationBudget(uword size);

  void DecreaseAllocationBudget(uword size);

  void SetAllocationBudget(word new_budget);

  void ClearMarkBits();

  // Tells whether garbage collection is needed.  Only to be called when
  // bump allocation has failed, or on old space after a new-space GC.
  // For a fixed-size new-space it always returns true because we always
  // want to do a new-space GC when the single chunk fills up.
  bool needs_garbage_collection() {
    return allocation_budget_ <= 0 || !resizeable_;
  }

  bool in_no_allocation_failure_scope() {
    return no_allocation_failure_nesting_ != 0;
  }

  bool is_empty() const { return chunk_list_.IsEmpty(); }

  ChunkListIterator ChunkListBegin() { return chunk_list_.Begin(); }
  ChunkListIterator ChunkListEnd() { return chunk_list_.End(); }

  static uword DefaultChunkSize(uword heap_size) {
    // We return a value between kDefaultMinimumChunkSize and
    // kDefaultMaximumChunkSize - and try to keep the chunks smaller than 20% of
    // the heap.
    return Utils::Minimum(
        Utils::Maximum(kDefaultMinimumChunkSize, heap_size / 5),
        kDefaultMaximumChunkSize);
  }

  // Obtain the offset of [object] from the start of the chunk. We assume
  // there is exactly one chunk in this space and [object] lies within it.
  word OffsetOf(HeapObject* object);
  HeapObject* ObjectAtOffset(word offset);

#ifdef DEBUG
  void Find(uword word, const char* name);
#endif

  uword start() {
    ASSERT(chunk_list_.First() == chunk_list_.Last());
    return chunk_list_.First()->start();
  }

  uword size() {
    ASSERT(chunk_list_.First() == chunk_list_.Last());
    return chunk_list_.First()->size();
  }

  bool IsInSingleChunk(HeapObject* object) {
    ASSERT(chunk_list_.First() == chunk_list_.Last());
    return reinterpret_cast<uword>(object) - start() < size();
  }

  Chunk* chunk() {
    ASSERT(chunk_list_.First() == chunk_list_.Last());
    return chunk_list_.First();
  }

  WeakPointerList* weak_pointers() { return &weak_pointers_; }

  PageType page_type() { return page_type_; }

 protected:
  explicit Space(Resizing resizeable, PageType page_type);

  friend class Chunk;
  friend class CompactingVisitor;
  friend class NoAllocationFailureScope;
  friend class Program;
  friend class ProgramHeapRelocator;
  friend class TwoSpaceHeap;

  virtual void Append(Chunk* chunk);

  void FreeAllChunks();

  uword top() { return top_; }

  void IncrementNoAllocationFailureNesting() {
    ASSERT(resizeable_);  // Fixed size heap cannot guarantee allocation.
    ++no_allocation_failure_nesting_;
  }

  void DecrementNoAllocationFailureNesting() {
    --no_allocation_failure_nesting_;
  }

  ChunkList chunk_list_;
  uword used_;              // Allocated bytes.
  uword top_;               // Allocation top in current chunk.
  uword limit_;             // Allocation limit in current chunk.
  // The allocation budget can be used to trigger a GC early, eg. in response
  // to large amounts of external allocation. If the allocation budget is not
  // hit, we may still trigger a GC because we are getting close to the limit
  // for the committed size of the chunks in the heap.
  word allocation_budget_;
  int no_allocation_failure_nesting_;
  bool resizeable_;

  // Linked list of weak pointers to heap objects in this space.
  WeakPointerList weak_pointers_;
  PageType page_type_;
};

class SemiSpace : public Space {
 public:
  explicit SemiSpace(Resizing resizeable, PageType page_type,
                     uword maximum_initial_size);

  // Returns the total size of allocated objects.
  virtual uword Used();

  virtual bool IsAlive(HeapObject* old_location);
  virtual HeapObject* NewLocation(HeapObject* old_location);

  // Instance transformation leaves garbage in the heap that needs to be
  // added to freelists when using mark-sweep collection.
  virtual void RebuildAfterTransformations();

  // Flush will make the current chunk consistent for iteration.
  virtual void Flush();

  bool IsFlushed();

  void TriggerGCSoon() { limit_ = top_ + kSentinelSize; }

  // Allocate raw object. Returns 0 if a garbage collection is needed
  // and causes a fatal error if no garbage collection is needed and
  // there is no room to allocate the object.
  uword Allocate(uword size);

  // For the program semispaces.  There is no other space into which we
  // promote, so it does all work in one go.
  void CompleteScavenge(PointerVisitor* visitor);

  // For the mutable heap.
  void StartScavenge();
  bool CompleteScavengeGenerational(GenerationalScavengeVisitor* visitor);

  void UpdateBaseAndLimit(Chunk* chunk, uword top);

  virtual void Append(Chunk* chunk);

  void SetReadOnly() { top_ = limit_ = 0; }

  void ProcessWeakPointers(SemiSpace* to_space, OldSpace* old_space);

 private:
  Chunk* AllocateAndUseChunk(uword size);

  uword AllocateInNewChunk(uword size);

  uword TryAllocate(uword size);
};

class OldSpace : public Space {
 public:
  explicit OldSpace(TwoSpaceHeap* heap);

  virtual ~OldSpace();

  virtual bool IsAlive(HeapObject* old_location);

  virtual HeapObject* NewLocation(HeapObject* old_location);

  virtual uword Used();

  // Instance transformation leaves garbage in the heap that needs to be
  // added to freelists when using mark-sweep collection.
  virtual void RebuildAfterTransformations();

  // Flush will make the current chunk consistent for iteration.
  virtual void Flush();

  // Allocate raw object. Returns 0 if a garbage collection is needed
  // and causes a fatal error if no garbage collection is needed and
  // there is no room to allocate the object.
  uword Allocate(uword size);

  FreeList* free_list() { return free_list_; }

  void ClearFreeList();
  void MarkChunkEndsFree();
  void ZapObjectStarts();

  // Find pointers to young-space.
  void VisitRememberedSet(GenerationalScavengeVisitor* visitor);

  // For the objects promoted to the old space during scavenge.
  inline void StartScavenge() { StartTrackingAllocations(); }
  bool CompleteScavengeGenerational(GenerationalScavengeVisitor* visitor);
  inline void EndScavenge() { EndTrackingAllocations(); }

  void StartTrackingAllocations();
  void EndTrackingAllocations();
  void UnlinkPromotedTrack();

  void UseWholeChunk(Chunk* chunk);

  void ProcessWeakPointers();

  void ComputeCompactionDestinations();

#ifdef DEBUG
  void Verify();
#endif

  void set_compacting(bool value) { compacting_ = value; }
  bool compacting() { return compacting_; }

  void clear_hard_limit_hit() { hard_limit_hit_ = false; }
  void set_used_after_last_gc(uword used) { used_after_last_gc_ = used; }

  // For detecting pointless GCs that are really an out-of-memory situation.
  void EvaluatePointlessness();
  uword MinimumProgress();
  void ReportNewSpaceProgress(uword bytes_collected);

 private:
  uword AllocateFromFreeList(uword size);
  uword AllocateInNewChunk(uword size);
  Chunk* AllocateAndUseChunk(uword size);

  TwoSpaceHeap* heap_;
  FreeList* free_list_;  // Free list structure.
  bool tracking_allocations_ = false;
  PromotedTrack* promoted_track_ = NULL;
  bool compacting_ = true;

  // Actually new space garbage found since last compacting GC. Used to
  // evaluate whether we are out of memory.
  uword new_space_garbage_found_since_last_gc_ = 0;
  int successive_pointless_gcs_ = 0;
  uword used_after_last_gc_ = 0;
  bool hard_limit_hit_ = false;
};

class NoAllocationFailureScope {
 public:
  explicit NoAllocationFailureScope(Space* space) : space_(space) {
    space->IncrementNoAllocationFailureNesting();
  }

  ~NoAllocationFailureScope() { space_->DecrementNoAllocationFailureNesting(); }

 private:
  Space* space_;
};

class NoAllocationScope {
 public:
#ifndef DEBUG
  explicit NoAllocationScope(Heap* heap) {}
#else
  explicit NoAllocationScope(Heap* heap);
  ~NoAllocationScope();

 private:
  Heap* heap_;
#endif
};

// ObjectMemory controls all memory used by object heaps.
class ObjectMemory {
 public:
  // Allocate a new chunk for a given space. All chunk sizes are
  // rounded up the page size and the allocated memory is aligned
  // to a page boundary.
  static Chunk* AllocateChunk(Space* space, uword size);

  // Create a chunk for a piece of external memory (usually in flash). Since
  // this memory is external and potentially read-only, we will not free
  // nor write to it when deleting the space it belongs to.
  static Chunk* CreateFlashChunk(Space* space, void* heap_space, uword size) {
    return CreateFixedChunk(space, heap_space, size);
  }

  // Release the chunk.
  static void FreeChunk(Chunk* chunk);

  // Setup and tear-down support.
  static void Setup();
  static void TearDown();

  static uword Allocated() { return allocated_; }

 private:
  // Use some already-existing memory for a chunk.
  static Chunk* CreateFixedChunk(Space* space, void* heap_space, uword size);

  static Atomic<uword> allocated_;

  friend class SemiSpace;
  friend class Space;
};

}  // namespace dartino

#endif  // SRC_VM_OBJECT_MEMORY_H_
