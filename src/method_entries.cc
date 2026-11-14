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

#include "method_entries.h"

#include "bytecodes.h"
#include "objects.h"
#include "program.h"

#include "objects_inline.h"

namespace toit {

#define BYTECODE_LENGTH(name, length, format, print) length,
static const uint8 opcode_lengths[] = { BYTECODES(BYTECODE_LENGTH) };
#undef BYTECODE_LENGTH

namespace {

class Bitmap {
 public:
  explicit Bitmap(uword length)
      : length_(length)
      , bits_(unvoid_cast<uint8*>(calloc((length + 7) >> 3, 1))) {}
  ~Bitmap() { free(bits_); }

  bool is_valid() const { return bits_ != null; }
  bool get(uword index) const { return ((bits_[index >> 3] >> (index & 7)) & 1) != 0; }
  void set(uword index) { bits_[index >> 3] |= 1 << (index & 7); }

  uint8* get_bits() const { return bits_; }

  // Gives up ownership of the bits.
  uint8* take() {
    uint8* result = bits_;
    bits_ = null;
    return result;
  }

 private:
  const uword length_;
  uint8* bits_;
};

// A growable stack of bytecode indexes.
class Worklist {
 public:
  ~Worklist() { free(data_); }

  bool push(uword value) {
    if (size_ == capacity_) {
      uword new_capacity = capacity_ == 0 ? 256 : capacity_ * 2;
      uword* new_data = unvoid_cast<uword*>(realloc(data_, new_capacity * sizeof(uword)));
      if (new_data == null) return false;
      data_ = new_data;
      capacity_ = new_capacity;
    }
    data_[size_++] = value;
    return true;
  }

  bool is_empty() const { return size_ == 0; }
  uword pop() { return data_[--size_]; }

 private:
  uword* data_ = null;
  uword size_ = 0;
  uword capacity_ = 0;
};

class EntryWalker {
 public:
  EntryWalker(Program* program, Bitmap* entries)
      : program_(program)
      , bytes_(program->bytecodes.data())
      , length_(program->bytecodes.length())
      , entries_(entries)
      , visited_(program->bytecodes.length()) {}

  bool run();
  word count() const { return count_; }

 private:
  Program* const program_;
  const uint8* const bytes_;
  const uword length_;
  Bitmap* const entries_;
  Bitmap visited_;
  Worklist worklist_;
  word count_ = 0;
  bool failed_ = false;

  bool is_header(word id) const {
    return id >= 0 && static_cast<uword>(id) + Method::entry_offset() <= length_;
  }

  void add_method(word id) {
    if (!is_header(id) || entries_->get(id)) return;
    entries_->set(id);
    count_++;
    add_code(id + Method::entry_offset());
  }

  void add_code(uword bci) {
    if (bci >= length_ || visited_.get(bci)) return;
    if (!worklist_.push(bci)) failed_ = true;
  }

  bool is_interface_stub(Method method, Bitmap* interface_selectors, word dispatch_length);
  void decode_from(uword bci);
};

bool EntryWalker::is_interface_stub(Method method, Bitmap* interface_selectors, word dispatch_length) {
  word selector = method.selector_offset();
  return selector >= 0 && selector < dispatch_length && interface_selectors->get(selector);
}

// Decodes the straight-line code starting at bci, queueing branch targets
// and the methods loaded by LOAD_METHOD.
void EntryWalker::decode_from(uword bci) {
  while (bci < length_ && !visited_.get(bci)) {
    visited_.set(bci);
    int opcode = bytes_[bci];
    if (opcode >= ILLEGAL_END) return;
    uword length = opcode_lengths[opcode];
    if (bci + length > length_) return;
    const uint8* bcp = bytes_ + bci;
    switch (opcode) {
      case LOAD_METHOD: {
        word id = Utils::read_unaligned_uint32(bcp + 1);
        if (is_header(id)) {
          Method method(const_cast<uint8*>(bytes_) + id);
          if (method.is_block_method() || method.is_lambda_method()) add_method(id);
        }
        break;
      }
      case BRANCH:
        add_code(bci + Utils::read_unaligned_uint16(bcp + 1));
        return;
      case BRANCH_IF_TRUE:
      case BRANCH_IF_FALSE:
      case BRANCH_IF_NOT_NULL:
        add_code(bci + Utils::read_unaligned_uint16(bcp + 1));
        break;
      case BRANCH_BACK:
        add_code(bci - Utils::read_unaligned_uint16(bcp + 1));
        return;
      case BRANCH_BACK_IF_TRUE:
      case BRANCH_BACK_IF_FALSE:
      case BRANCH_BACK_IF_NOT_NULL:
        add_code(bci - Utils::read_unaligned_uint16(bcp + 1));
        break;
      case NON_LOCAL_BRANCH:
        add_code(Utils::read_unaligned_uint32(bcp + 2));
        return;
      case HALT:
        // Only 'yield' (0) continues with the next instruction.
        if (bcp[1] != 0) return;
        break;
      case RETURN:
      case RETURN_NULL:
      case THROW:
      case INVOKE_STATIC_TAIL:
      case INVOKE_INITIALIZER_TAIL:
      case NON_LOCAL_RETURN:
      case NON_LOCAL_RETURN_WIDE:
        return;
      default:
        break;
    }
    bci += length;
  }
}

bool EntryWalker::run() {
  if (!visited_.is_valid()) return false;
  word dispatch_length = program_->dispatch_table.length();
  Bitmap interface_selectors(dispatch_length);
  if (!interface_selectors.is_valid()) return false;
  for (word i = 0; i < program_->interface_check_offsets.length(); i++) {
    word selector = program_->interface_check_offsets[i];
    if (selector < dispatch_length) interface_selectors.set(selector);
  }

  // Roots: the dispatch table, except for the interface-check stubs. Those
  // have no code (their entry is the header of the next method) and are only
  // used by the 'is' and 'as' checks for interfaces.
  for (word i = 0; i < dispatch_length; i++) {
    word id = program_->dispatch_table[i];
    if (!is_header(id)) continue;
    Method method(const_cast<uint8*>(bytes_) + id);
    if (is_interface_stub(method, &interface_selectors, dispatch_length)) continue;
    add_method(id);
  }

  // Roots: the methods of the lazy initializers of global variables.
  Smi* lazy_class_id = program_->lazy_initializer_class_id();
  word class_count = program_->class_bits.length();
  word lazy_id = Smi::value(lazy_class_id);
  if (0 <= lazy_id && lazy_id < class_count &&
      Program::class_tag_from_class_bits(program_->class_bits[lazy_id]) == INSTANCE_TAG &&
      program_->instance_fields_for(lazy_class_id) >= 1) {
    for (word i = 0; i < program_->global_variables.length(); i++) {
      Object* value = program_->global_variables.at(i);
      if (!is_heap_object(value)) continue;
      HeapObject* object = HeapObject::cast(value);
      if (object->class_id() != lazy_class_id) continue;
      Object* id = Instance::cast(object)->at(0);
      if (is_smi(id)) add_method(Smi::value(id));
    }
  }

  while (!worklist_.is_empty() && !failed_) {
    decode_from(worklist_.pop());
  }
  return !failed_;
}

}  // namespace

MethodEntryTable::~MethodEntryTable() {
  free(bits_);
}

MethodEntryTable* MethodEntryTable::compute(Program* program) {
  uword length = program->bytecodes.length();
  Bitmap entries(length);
  if (!entries.is_valid()) return null;
  EntryWalker walker(program, &entries);
  if (!walker.run()) return null;
  MethodEntryTable* result = _new MethodEntryTable(entries.get_bits(), length);
  if (result == null) return null;
  entries.take();  // The table owns the bits now.
  result->count_ = walker.count();
  return result;
}

} // namespace toit
