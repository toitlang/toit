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

class ProgramBlock;
class ProgramHeap;
class ProgramRawHeap;

// A class used for printing usage of a memory area.
class ProgramUsage {
 public:
  explicit ProgramUsage(const char* name) : _name(name), _reserved(0), _allocated(0) {}
  ProgramUsage(const char* name, int reserved) : _name(name), _reserved(reserved), _allocated(reserved) {}
  ProgramUsage(const char* name, int reserved, int allocated) : _name(name), _reserved(reserved), _allocated(allocated) {}

  // For accumulating usage information.
  void add(ProgramUsage* other) {
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

typedef LinkedFIFO<ProgramBlock> ProgramBlockLinkedList;

class ProgramBlock : public ProgramBlockLinkedList::Element {
 public:
  ProgramBlock() {
    _reset();
  }

  static ProgramBlock* allocate_program_block() {
    void* result = malloc(TOIT_PAGE_SIZE);
    return new (result) ProgramBlock();
  }

  void* top() const { return _top; }
  void* base() const { return Utils::address_at(const_cast<ProgramBlock*>(this), sizeof(ProgramBlock)); }
  void* limit() const { return Utils::address_at(const_cast<ProgramBlock*>(this), TOIT_PAGE_SIZE); }

  HeapObject* allocate_raw(int byte_size);

  bool is_empty() { return top() == base(); }

  void do_pointers(Program* program, PointerCallback* callback);

  // Returns the number of bytes allocated.
  int payload_size() const { return reinterpret_cast<uword>(top()) - reinterpret_cast<uword>(base()); }

  void print();

 private:
  // How many bytes are available for payload in one Block?
  static int max_payload_size(int word_size = WORD_SIZE) {
    ASSERT(sizeof(ProgramBlock) == 2 * WORD_SIZE);
    if (word_size == 4) {
      return TOIT_PAGE_SIZE_32 - 2 * word_size;
    } else {
      return TOIT_PAGE_SIZE_64 - 2 * word_size;
    }
  }

  void _reset() {
    _top = base();
  }

  void wipe();

  void* _top;
  friend class ProgramBlockList;
  friend class ProgramHeap;
  friend class ProgramHeapMemory;
};

class ProgramBlockList {
 public:
  ProgramBlockList() : _length(0) { }
  ~ProgramBlockList();

  // Returns the number of bytes allocated.
  int payload_size() const;

  void set_writable(bool value);

  void append(ProgramBlock* b) {
    _blocks.append(b);
    _length++;
  }

  void prepend(ProgramBlock* b) {
    _blocks.prepend(b);
    _length++;
  }

  bool is_empty() const {
    return _blocks.is_empty();
  }

  ProgramBlock* first() const {
    return _blocks.first();
  }

  ProgramBlock* remove_first() {
    ProgramBlock* block = _blocks.remove_first();
    if (block) _length--;
    return block;
  }

  ProgramBlock* last() const {
    return _blocks.last();
  }

  void take_blocks(ProgramBlockList* list, ProgramRawHeap* heap);
  void free_blocks(ProgramRawHeap* heap);
  void discard_blocks();

  word length() const { return _length; }

  void do_pointers(Program* program, PointerCallback* callback);

  void print();

  typename ProgramBlockLinkedList::Iterator begin() { return _blocks.begin(); }
  typename ProgramBlockLinkedList::Iterator end() { return _blocks.end(); }

 private:
  ProgramBlockLinkedList _blocks;
  word _length;  // Number of blocks in the this list.
};

// Memory provide blocks for objects.
class ProgramHeapMemory {
 public:

  void set_writable(ProgramBlock* block, bool value);

  Mutex* mutex() const { return _memory_mutex; }

  static ProgramHeapMemory* instance() { return &_instance; }

  ProgramHeapMemory();
  ~ProgramHeapMemory();

 private:
  static ProgramHeapMemory _instance;

  Mutex* _memory_mutex;
};

class ProgramRawHeap {
 public:
  ProgramRawHeap() { }

  void take_blocks(ProgramBlockList* blocks);

  // Size of all objects stored in this heap.
  int object_size() const {
    return _blocks.payload_size();
  }

  // Number of blocks allocated.  This is used for reserving space for a GC, so
  // it does not include off-heap allocations which don't need to be moved in a
  // GC.
  word number_of_blocks() const { return _blocks.length(); }

  ProgramUsage usage(const char* name);
  void print();

  // Should only be called from ProgramImage.
  void do_pointers(Program* program, PointerCallback* callback) {
    _blocks.do_pointers(program, callback);
  }

 protected:
  ProgramBlockList _blocks;

 private:
  friend class ImageAllocator;
  friend class Program;
};

} // namespace toit
