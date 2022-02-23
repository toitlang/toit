// Copyright (C) 2018 Toitware ApS.
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

#pragma once

#include "linked.h"
#include "top.h"
#include "utils.h"

namespace toit {

class Heap;
class RawHeap;

// A class used for printing usage of a memory area.
class Usage {
 public:
  explicit Usage(const char* name) : _name(name), _reserved(0), _allocated(0) {}
  Usage(const char* name, int reserved) : _name(name), _reserved(reserved), _allocated(reserved) {}
  Usage(const char* name, int reserved, int allocated) : _name(name), _reserved(reserved), _allocated(allocated) {}

  // For accumulating usage information.
  void add(Usage* other) {
    _reserved += other->_reserved;
    _allocated += other->_allocated;
  }

  void add_external(int allocated) {
    _reserved += allocated;
    _allocated += allocated;
  }

  void print(int indent = 0);

  const char* name() { return _name; }
  int reserved() const { return _reserved; }
  int allocated() const { return _allocated; }

 private:
  const char* _name;
  int _reserved;
  int _allocated;
};

// Memory provide chunks for objects.
class HeapMemory {
 public:

  // Memory management (MT safe operations)
  Chunk* allocate_chunk(RawHeap* heap);
  Chunk* allocate_initial_chunk();
  Chunk* allocate_chunk_during_scavenge(RawHeap* heap);
  void free_chunk(Chunk* chunk, RawHeap* heap);
  void enter_scavenge(RawHeap* heap);
  void leave_scavenge(RawHeap* heap);

  // This is used for the case where we allocated an initial chunk for a new
  // heap, but the new heap creation failed, so the chunk was never associated
  // with a heap or a process.
  void free_unused_chunk(Chunk* chunk);

  Mutex* mutex() const { return _memory_mutex; }

 private:
  HeapMemory();
  ~HeapMemory();

  ChunkList _free_list;
  Mutex* _memory_mutex;
  bool _in_scavenge = false;
  word _largest_number_of_chunks_in_a_heap = 0;  // In pages.

  friend class VM;
};

class RawHeap {
 public:
  explicit RawHeap(Process* owner) : _owner(owner) { }
  RawHeap() : _owner(null) { }

  Process* owner() { return _owner; }

  void take_chunks(ChunkList* chunks);

  // Size of all objects stored in this heap.
  int object_size() const {
    return _chunks.payload_size();
  }

  // Number of chunks allocated.  This is used for reserving space for a GC, so
  // it does not include off-heap allocations which don't need to be moved in a
  // GC.
  word number_of_chunks() const { return _chunks.length(); }

  Usage usage(const char* name);
  void print();

 protected:
  ChunkList _chunks;

 private:
  Process* const _owner;
  friend class ImageAllocator;
  friend class Program;
};

} // namespace toit
