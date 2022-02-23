// Copyright (c) 2014, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#include "src/vm/heap.h"

#include <stdio.h>

#include "src/shared/assert.h"
#include "src/shared/flags.h"
#include "src/vm/object.h"

namespace dartino {

Heap::Heap(RandomXorShift* random)
    : random_(random), space_(NULL), foreign_memory_(0) {}

OneSpaceHeap::OneSpaceHeap(RandomXorShift* random, int maximum_initial_size)
    : Heap(random) {
  space_ =
      new SemiSpace(Space::kCanResize, kUnknownSpacePage, maximum_initial_size);
  AdjustAllocationBudget();
}

TwoSpaceHeap::TwoSpaceHeap()
    : Heap(reinterpret_cast<RandomXorShift*>(NULL)),
      old_space_(new OldSpace(this)),
      unused_semispace_(new SemiSpace(Space::kCannotResize, kNewSpacePage, 0)) {
  space_ = new SemiSpace(Space::kCannotResize, kNewSpacePage, 0);
  uword size = Utils::RoundUp(Flags::semispace_size << 10, Platform::kPageSize);
  size = Utils::Minimum(1ul << 24,
                        Utils::Maximum(size, 0ul + Platform::kPageSize));
  semispace_size_ = size;
  max_size_ = Utils::RoundUp(Flags::max_heap_size * 1024, Platform::kPageSize);
}

bool TwoSpaceHeap::Initialize() {
  Chunk* chunk = ObjectMemory::AllocateChunk(space_, semispace_size_);
  if (chunk == NULL) return false;
  Chunk* unused_chunk =
      ObjectMemory::AllocateChunk(unused_semispace_, semispace_size_);
  if (unused_chunk == NULL) {
    ObjectMemory::FreeChunk(chunk);
    return false;
  }
  space_->Append(chunk);
  space_->UpdateBaseAndLimit(chunk, chunk->start());
  unused_semispace_->Append(unused_chunk);
  AdjustAllocationBudget();
  AdjustOldAllocationBudget();
  water_mark_ = chunk->start();
  return true;
}

uword TwoSpaceHeap::MaxExpansion() {
  if (max_size_ == 0) return kUnlimitedExpansion;
  if (semispace_size_ * 2 > max_size_) return 0;
  uword max = max_size_ - 2 * semispace_size_;
  uword old_space_size = old_space_->Size();
  if (max < old_space_size) return 0;
  return max - old_space_size;
}

Heap::~Heap() {
  delete space_;
  ASSERT(foreign_memory_ == 0);
}

TwoSpaceHeap::~TwoSpaceHeap() {
  // We do this before starting to destroy the heap, because the callbacks can
  // trigger calls that assume the heap is still working.
  WeakPointer::ForceCallbacks(old_space_->weak_pointers());
  WeakPointer::ForceCallbacks(space_->weak_pointers());
  delete unused_semispace_;
  delete old_space_;
}

Object* Heap::Allocate(uword size) {
  ASSERT(no_allocation_ == 0);
  uword result = space_->Allocate(size);
  if (result == 0) {
    return HandleAllocationFailure(size);
  }
  return HeapObject::FromAddress(result);
}

Object* Heap::CreateBooleanObject(uword position, Class* the_class,
                                  Object* init_value) {
  HeapObject* raw_result = HeapObject::FromAddress(position);
  Instance* result = reinterpret_cast<Instance*>(raw_result);
  result->set_class(the_class);
  result->set_immutable(true);
  result->InitializeIdentityHashCode(random());
  result->Initialize(the_class->instance_format().fixed_size(), init_value);
  return result;
}

Object* Heap::CreateInstance(Class* the_class, Object* init_value,
                             bool immutable) {
  uword size = the_class->instance_format().fixed_size();
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Instance* result = reinterpret_cast<Instance*>(raw_result);
  result->set_class(the_class);
  result->set_immutable(immutable);
  if (immutable) result->InitializeIdentityHashCode(random());
  ASSERT(size == the_class->instance_format().fixed_size());
  result->Initialize(size, init_value);
  return result;
}

Object* TwoSpaceHeap::CreateOldSpaceInstance(Class* the_class,
                                             Object* init_value) {
  uword size = the_class->instance_format().fixed_size();
  uword new_address = old_space_->Allocate(size);
  ASSERT(new_address != 0);  // Only used in NoAllocationFailureScope.
  Instance* result =
      reinterpret_cast<Instance*>(HeapObject::FromAddress(new_address));
  result->set_class(the_class);
  result->set_immutable(false);
  ASSERT(size == the_class->instance_format().fixed_size());
  result->Initialize(size, init_value);
  return result;
}

Object* Heap::CreateArray(Class* the_class, int length, Object* init_value) {
  ASSERT(the_class->instance_format().type() == InstanceFormat::ARRAY_TYPE);
  uword size = Array::AllocationSize(length);
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Array* result = reinterpret_cast<Array*>(raw_result);
  result->set_class(the_class);
  result->Initialize(length, size, init_value);
  return Array::cast(result);
}

Object* Heap::CreateByteArray(Class* the_class, int length) {
  ASSERT(the_class->instance_format().type() ==
         InstanceFormat::BYTE_ARRAY_TYPE);
  uword size = ByteArray::AllocationSize(length);
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  ByteArray* result = reinterpret_cast<ByteArray*>(raw_result);
  result->set_class(the_class);
  result->Initialize(length);
  return ByteArray::cast(result);
}

Object* Heap::CreateLargeInteger(Class* the_class, int64 value) {
  ASSERT(the_class->instance_format().type() ==
         InstanceFormat::LARGE_INTEGER_TYPE);
  uword size = LargeInteger::AllocationSize();
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  LargeInteger* result = reinterpret_cast<LargeInteger*>(raw_result);
  result->set_class(the_class);
  result->set_value(value);
  return LargeInteger::cast(result);
}

Object* Heap::CreateDouble(Class* the_class, dartino_double value) {
  ASSERT(the_class->instance_format().type() == InstanceFormat::DOUBLE_TYPE);
  uword size = Double::AllocationSize();
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Double* result = reinterpret_cast<Double*>(raw_result);
  result->set_class(the_class);
  result->set_value(value);
  return Double::cast(result);
}

Object* Heap::CreateBoxed(Class* the_class, Object* value) {
  ASSERT(the_class->instance_format().type() == InstanceFormat::BOXED_TYPE);
  uword size = the_class->instance_format().fixed_size();
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Boxed* result = reinterpret_cast<Boxed*>(raw_result);
  result->set_class(the_class);
  result->set_value(value);
  return Boxed::cast(result);
}

Object* Heap::CreateInitializer(Class* the_class, Function* function) {
  ASSERT(the_class->instance_format().type() ==
         InstanceFormat::INITIALIZER_TYPE);
  uword size = the_class->instance_format().fixed_size();
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Initializer* result = reinterpret_cast<Initializer*>(raw_result);
  result->set_class(the_class);
  result->set_function(function);
  return Initializer::cast(result);
}

Object* Heap::CreateDispatchTableEntry(Class* the_class) {
  ASSERT(the_class->instance_format().type() ==
         InstanceFormat::DISPATCH_TABLE_ENTRY_TYPE);
  uword size = DispatchTableEntry::AllocationSize();
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  DispatchTableEntry* result =
      reinterpret_cast<DispatchTableEntry*>(raw_result);
  result->set_class(the_class);
  return DispatchTableEntry::cast(result);
}

Object* Heap::CreateOneByteStringInternal(Class* the_class, int length,
                                          bool clear) {
  ASSERT(the_class->instance_format().type() ==
         InstanceFormat::ONE_BYTE_STRING_TYPE);
  uword size = OneByteString::AllocationSize(length);
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  OneByteString* result = reinterpret_cast<OneByteString*>(raw_result);
  result->set_class(the_class);
  result->Initialize(size, length, clear);
  return OneByteString::cast(result);
}

Object* Heap::CreateTwoByteStringInternal(Class* the_class, int length,
                                          bool clear) {
  ASSERT(the_class->instance_format().type() ==
         InstanceFormat::TWO_BYTE_STRING_TYPE);
  uword size = TwoByteString::AllocationSize(length);
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  TwoByteString* result = reinterpret_cast<TwoByteString*>(raw_result);
  result->set_class(the_class);
  result->Initialize(size, length, clear);
  return TwoByteString::cast(result);
}

Object* Heap::CreateOneByteString(Class* the_class, int length) {
  return CreateOneByteStringInternal(the_class, length, true);
}

Object* Heap::CreateTwoByteString(Class* the_class, int length) {
  return CreateTwoByteStringInternal(the_class, length, true);
}

Object* Heap::CreateOneByteStringUninitialized(Class* the_class, int length) {
  return CreateOneByteStringInternal(the_class, length, false);
}

Object* Heap::CreateTwoByteStringUninitialized(Class* the_class, int length) {
  return CreateTwoByteStringInternal(the_class, length, false);
}

Object* Heap::CreateStack(Class* the_class, int length) {
  ASSERT(the_class->instance_format().type() == InstanceFormat::STACK_TYPE);
  uword size = Stack::AllocationSize(length);
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Stack* result = reinterpret_cast<Stack*>(raw_result);
  result->set_class(the_class);
  result->Initialize(length);
  return Stack::cast(result);
}

Object* Heap::AllocateRawClass(uword size) { return Allocate(size); }

Object* Heap::CreateMetaClass() {
  InstanceFormat format = InstanceFormat::class_format();
  uword size = Class::AllocationSize();
  // Allocate the raw class objects.
  Class* meta_class = reinterpret_cast<Class*>(AllocateRawClass(size));
  if (meta_class->IsFailure()) return meta_class;
  // Bind the class loop.
  meta_class->set_class(meta_class);
  // Initialize the classes.
  meta_class->Initialize(format, size, NULL);
  return meta_class;
}

Object* Heap::CreateClass(InstanceFormat format, Class* meta_class,
                          HeapObject* null) {
  ASSERT(meta_class->instance_format().type() == InstanceFormat::CLASS_TYPE);

  uword size = meta_class->instance_format().fixed_size();
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Class* result = reinterpret_cast<Class*>(raw_result);
  result->set_class(meta_class);
  result->Initialize(format, size, null);
  return Class::cast(result);  // Perform a cast to validate type.
}

Object* Heap::CreateFunction(Class* the_class, int arity, List<uint8> bytecodes,
                             int number_of_literals) {
  ASSERT(the_class->instance_format().type() == InstanceFormat::FUNCTION_TYPE);
  int literals_size = number_of_literals * kPointerSize;
  int bytecode_size = Function::BytecodeAllocationSize(bytecodes.length());
  uword size = Function::AllocationSize(bytecode_size + literals_size);
  Object* raw_result = Allocate(size);
  if (raw_result->IsFailure()) return raw_result;
  Function* result = reinterpret_cast<Function*>(raw_result);
  result->set_class(the_class);
  result->set_arity(arity);
  result->set_literals_size(number_of_literals);
  result->Initialize(bytecodes);
  return Function::cast(result);
}

void TwoSpaceHeap::AllocatedForeignMemory(uword size) {
  ASSERT(static_cast<word>(foreign_memory_) >= 0);
  foreign_memory_ += size;
  old_space()->DecreaseAllocationBudget(size);
  if (old_space()->needs_garbage_collection()) {
    space()->TriggerGCSoon();
  }
}

void TwoSpaceHeap::FreedForeignMemory(uword size) {
  foreign_memory_ -= size;
  ASSERT(static_cast<word>(foreign_memory_) >= 0);
  old_space()->IncreaseAllocationBudget(size);
}

void TwoSpaceHeap::SwapSemiSpaces() {
  SemiSpace* temp = space_;
  space_ = unused_semispace_;
  unused_semispace_ = temp;
  water_mark_ = space_->top();
}

void Heap::ReplaceSpace(SemiSpace* space) {
  delete space_;
  space_ = space;
  AdjustAllocationBudget();
}

SemiSpace* Heap::TakeSpace() {
  SemiSpace* result = space_;
  space_ = NULL;
  return result;
}

void TwoSpaceHeap::AddWeakPointer(HeapObject* object,
                                  WeakPointerCallback callback, void* arg) {
  WeakPointer* weak_pointer = new WeakPointer(object, callback, arg);
  if (space_->IsInSingleChunk(object)) {
    space_->weak_pointers()->Append(weak_pointer);
  } else {
    ASSERT(old_space_->Includes(object->address()));
    old_space_->weak_pointers()->Append(weak_pointer);
  }
}

void TwoSpaceHeap::AddExternalWeakPointer(HeapObject* object,
                                          ExternalWeakPointerCallback callback,
                                          void* arg) {
  WeakPointer* weak_pointer = new WeakPointer(object, callback, arg);
  if (space_->IsInSingleChunk(object)) {
    space_->weak_pointers()->Append(weak_pointer);
  } else {
    ASSERT(old_space_->Includes(object->address()));
    old_space_->weak_pointers()->Append(weak_pointer);
  }
}

void TwoSpaceHeap::RemoveWeakPointer(HeapObject* object) {
  if (space_->IsInSingleChunk(object)) {
    bool success = WeakPointer::Remove(space_->weak_pointers(), object);
    ASSERT(success);
  } else {
    ASSERT(old_space_->Includes(object->address()));
    bool success = WeakPointer::Remove(old_space_->weak_pointers(), object);
    ASSERT(success);
  }
}

bool TwoSpaceHeap::RemoveExternalWeakPointer(
    HeapObject* object, ExternalWeakPointerCallback callback) {
  if (space_->IsInSingleChunk(object)) {
    return WeakPointer::Remove(space_->weak_pointers(), object, callback);
  } else {
    return WeakPointer::Remove(old_space_->weak_pointers(), object, callback);
  }
}

void GenerationalScavengeVisitor::VisitBlock(Object** start, Object** end) {
  for (Object** p = start; p < end; p++) {
    if (!InFromSpace(*p)) continue;
    HeapObject* old_object = reinterpret_cast<HeapObject*>(*p);
    if (old_object->HasForwardingAddress()) {
      HeapObject* destination = old_object->forwarding_address();
      *p = destination;
      if (InToSpace(destination)) *record_ = GCMetadata::kNewSpacePointers;
    } else {
      if (old_object->address() < water_mark_) {
        HeapObject* moved_object = old_object->CloneInToSpace(old_);
        // The old space may fill up.  This is a bad moment for a GC, so we
        // promote to the to-space instead.
        if (moved_object == NULL) {
          trigger_old_space_gc_ = true;
          moved_object = old_object->CloneInToSpace(to_);
          *record_ = GCMetadata::kNewSpacePointers;
        }
        *p = moved_object;
      } else {
        *p = old_object->CloneInToSpace(to_);
        *record_ = GCMetadata::kNewSpacePointers;
      }
      ASSERT(*p != NULL);  // In an emergency we can move to to-space.
    }
  }
}

void SemiSpace::StartScavenge() {
  Flush();

  for (auto chunk : chunk_list_) chunk->set_scavenge_pointer(chunk->start());
}

#ifdef DEBUG
void TwoSpaceHeap::Find(uword word) {
  space_->Find(word, "data semispace");
  unused_semispace_->Find(word, "unused semispace");
  old_space_->Find(word, "oldspace");
  Heap::Find(word);
}

void OneSpaceHeap::Find(uword word) {
  space_->Find(word, "program semispace");
  Heap::Find(word);
}

void Heap::Find(uword word) {
  space_->Find(word, "semispace");
#ifdef DARTINO_TARGET_OS_LINUX
  FILE* fp = fopen("/proc/self/maps", "r");
  if (fp == NULL) return;
  size_t length;
  char* line = NULL;
  while (getline(&line, &length, fp) > 0) {
    char* start;
    char* end;
    char r, w, x, p;  // Permissions.
    char filename[1000];
    memset(filename, 0, 1000);
    sscanf(line, "%p-%p %c%c%c%c %*x %*5c %*d %999c", &start, &end, &r, &w, &x,
           &p, &(filename[0]));
    // Don't search in mapped files.
    if (filename[0] != 0 && filename[0] != '[') continue;
    if (filename[0] == 0) {
      snprintf(filename, sizeof(filename), "anonymous: %p-%p %c%c%c%c", start,
               end, r, w, x, p);
    } else {
      if (filename[strlen(filename) - 1] == '\n') {
        filename[strlen(filename) - 1] = 0;
      }
    }
    // If we can't read it, skip.
    if (r != 'r') continue;
    for (char* current = start; current < end; current += 4) {
      uword w = *reinterpret_cast<uword*>(current);
      if (w == word) {
        fprintf(stderr, "Found %p in %s at %p\n", reinterpret_cast<void*>(w),
                filename, current);
      }
    }
  }
  fclose(fp);
#endif  // __linux
}
#endif  // DEBUG

}  // namespace dartino
