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

class Block;
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

typedef LinkedFIFO<Block> BlockLinkedList;

class Block : public BlockLinkedList::Element {
 public:
  Block() {
    _reset();
  }

  void* top() const { return _top; }
  void* base() const { return Utils::address_at(const_cast<Block*>(this), sizeof(Block)); }
  void* limit() const { return Utils::address_at(const_cast<Block*>(this), TOIT_PAGE_SIZE); }

  HeapObject* allocate_raw(int byte_size);

  Process* process() { return _process; }

  bool is_program() { return process() == null; }

  bool is_empty() { return top() == base(); }

  // How many bytes are available for payload in one Block?
  static int max_payload_size(int word_size = WORD_SIZE) {
    ASSERT(sizeof(Block) == 3 * WORD_SIZE);
    if (word_size == 4) {
      return TOIT_PAGE_SIZE_32 - 3 * word_size;
    } else {
      return TOIT_PAGE_SIZE_64 - 3 * word_size;
    }
  }

  // Returns the memory block that contains the object.
  static Block* from(HeapObject* object);

  // Tells whether this block of memory contains the object.
  bool contains(HeapObject* object);

  // Shift top with delta (not block content).
  void shrink_top(int delta);

  // Returns the number of bytes allocated.
  int payload_size() const { return reinterpret_cast<uword>(top()) - reinterpret_cast<uword>(base()); }

  void print();

 private:
  void _set_process(Process* value) {
    _process = value;
  }

  void _reset() {
    _process = null;
    _top = base();
  }

  void wipe();

  Process* _process;
  void* _top;
  friend class BlockList;
  friend class Heap;
  friend class HeapMemory;
  friend class OS;
  friend class RawMemory;
};

class BlockList {
 public:
  BlockList() : _length(0) { }
  ~BlockList();

  // Returns the number of bytes allocated.
  int payload_size() const;

  void set_writable(bool value);

  void append(Block* b) {
    _blocks.append(b);
    _length++;
  }

  void prepend(Block* b) {
    _blocks.prepend(b);
    _length++;
  }

  bool is_empty() const {
    return _blocks.is_empty();
  }

  Block* first() const {
    return _blocks.first();
  }

  Block* remove_first() {
    Block* block = _blocks.remove_first();
    if (block) _length--;
    return block;
  }

  Block* last() const {
    return _blocks.last();
  }

  void take_blocks(BlockList* list, RawHeap* heap);
  void free_blocks(RawHeap* heap);
  void discard_blocks();

  word length() const { return _length; }

  void print();

  typename BlockLinkedList::Iterator begin() { return _blocks.begin(); }
  typename BlockLinkedList::Iterator end() { return _blocks.end(); }

 private:
  BlockLinkedList _blocks;
  word _length;  // Number of blocks in the this list.
};

// Memory provide blocks for objects.
class HeapMemory {
 public:

  // Memory management (MT safe operations)
  Block* allocate_block(RawHeap* heap);
  Block* allocate_initial_block();
  Block* allocate_block_during_scavenge(RawHeap* heap);
  void free_block(Block* block, RawHeap* heap);
  void set_writable(Block* block, bool value);
  void enter_scavenge(RawHeap* heap);
  void leave_scavenge(RawHeap* heap);

  // This is used for the case where we allocated an initial block for a new
  // heap, but the new heap creation failed, so the block was never associated
  // with a heap or a process.
  void free_unused_block(Block* block);

  Mutex* mutex() const { return _memory_mutex; }

 private:
  HeapMemory();
  ~HeapMemory();

  BlockList _free_list;
  Mutex* _memory_mutex;
  bool _in_scavenge = false;
  word _largest_number_of_blocks_in_a_heap = 0;  // In pages.

  friend class VM;
};

class RawHeap {
 public:
  explicit RawHeap(Process* owner) : _owner(owner) { }
  RawHeap() : _owner(null) { }

  Process* owner() { return _owner; }

  void take_blocks(BlockList* blocks);

  // Size of all objects stored in this heap.
  int object_size() const {
    return _blocks.payload_size();
  }

  // Number of blocks allocated.  This is used for reserving space for a GC, so
  // it does not include off-heap allocations which don't need to be moved in a
  // GC.
  word number_of_blocks() const { return _blocks.length(); }

  Usage usage(const char* name);
  void print();

 protected:
  BlockList _blocks;

 private:
  Process* const _owner;
  friend class ImageAllocator;
  friend class Program;
};

} // namespace toit
