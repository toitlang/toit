// Copyright (C) 2023 Toitware ApS.
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

#include "flags.h"
#include "memory.h"
#include "objects_inline.h"
#include "encoder.h"
#include "printing.h"
#include "process.h"
#include "program_heap.h"
#include "snapshot.h"
#include "utils.h"

namespace toit {

bool Object::byte_content(Program* program, const uint8** content, word* length, BlobKind strings_only) const {
  if (is_string(this)) {
    String::Bytes bytes(String::cast(this));
    *length = bytes.length();
    *content = bytes.address();
    return true;
  }
  if (strings_only == STRINGS_OR_BYTE_ARRAYS && is_byte_array(this)) {
    const ByteArray* byte_array = ByteArray::cast(this);
    // External byte arrays can have structs in them. This is captured in the external tag.
    // We only allow extracting the byte content from an external byte arrays iff it is tagged with RawByteType.
    if (byte_array->has_external_address() && byte_array->external_tag() != RawByteTag) return false;
    ByteArray::ConstBytes bytes(byte_array);
    *length = bytes.length();
    *content = bytes.address();
    return true;
  }
  if (is_instance(this)) {
    auto instance = Instance::cast(this);
    auto class_id = instance->class_id();
    if (strings_only == STRINGS_OR_BYTE_ARRAYS && class_id == program->byte_array_cow_class_id()) {
      auto backing = instance->at(Instance::BYTE_ARRAY_COW_BACKING_INDEX);
      return backing->byte_content(program, content, length, strings_only);
    } else if ((strings_only == STRINGS_OR_BYTE_ARRAYS && class_id == program->byte_array_slice_class_id())
          || class_id == program->string_slice_class_id()
          || class_id == program->string_byte_slice_class_id()) {
      ASSERT(Instance::STRING_SLICE_STRING_INDEX == Instance::BYTE_ARRAY_SLICE_BYTE_ARRAY_INDEX);
      ASSERT(Instance::STRING_BYTE_SLICE_STRING_INDEX == Instance::BYTE_ARRAY_SLICE_BYTE_ARRAY_INDEX);
      ASSERT(Instance::STRING_SLICE_FROM_INDEX == Instance::BYTE_ARRAY_SLICE_FROM_INDEX);
      ASSERT(Instance::STRING_SLICE_TO_INDEX == Instance::BYTE_ARRAY_SLICE_TO_INDEX);
      auto wrapped = instance->at(Instance::STRING_SLICE_STRING_INDEX);
      auto from = instance->at(Instance::STRING_SLICE_FROM_INDEX);
      auto to = instance->at(Instance::STRING_SLICE_TO_INDEX);
      if (!is_heap_object(wrapped)) return false;
      // TODO(florian): we could eventually accept larger integers here.
      if (!is_smi(from)) return false;
      if (!is_smi(to)) return false;
      word from_value = Smi::value(from);
      word to_value = Smi::value(to);
      bool inner_success = HeapObject::cast(wrapped)->byte_content(program, content, length, strings_only);
      if (!inner_success) return false;
      if (0 <= from_value && from_value <= to_value && to_value <= *length) {
        *content += from_value;
        *length = to_value - from_value;
        return true;
      }
      return false;
    }
  }
  return false;
}

bool Object::byte_content(Program* program, Blob* blob, BlobKind strings_only) const {
  const uint8* content = null;
  word length = 0;
  bool result = byte_content(program, &content, &length, strings_only);
  *blob = Blob(content, length);
  return result;
}

bool Blob::slow_equals(const char* c_string) const {
  if (static_cast<size_t>(length()) != strlen(c_string)) return false;
  return memcmp(address(), c_string, length()) == 0;
}

word HeapObject::size(Program* program) const {
  word size = program->instance_size_for(this);
  if (size != 0) return size;
  switch (class_tag()) {
    case TypeTag::ARRAY_TAG:
      return Array::cast(this)->size();
    case TypeTag::BYTE_ARRAY_TAG:
      return ByteArray::cast(this)->size();
    case TypeTag::STACK_TAG:
      return Stack::cast(this)->size();
    case TypeTag::STRING_TAG:
      return String::cast(this)->size();
    case TypeTag::DOUBLE_TAG:
      return Double::allocation_size();
    case TypeTag::LARGE_INTEGER_TAG:
      return LargeInteger::allocation_size();
    case TypeTag::FREE_LIST_REGION_TAG:
      return FreeListRegion::cast(this)->size();
    case TypeTag::PROMOTED_TRACK_TAG:
      return PromotedTrack::cast(this)->size();
    default:
      FATAL("Unexpected class tag");
      return -1;
  }
}

void HeapObject::roots_do(Program* program, RootCallback* cb) {
  switch (class_tag()) {
    case TypeTag::ARRAY_TAG:
      Array::cast(this)->roots_do(cb);
      break;
    case TypeTag::STACK_TAG:
      Stack::cast(this)->roots_do(program, cb);
      break;
    case TypeTag::TASK_TAG:
    case TypeTag::INSTANCE_TAG:
      Instance::cast(this)->instance_roots_do(program->instance_size_for(this), cb);
      break;
    case TypeTag::STRING_TAG:
    case TypeTag::ODDBALL_TAG:
    case TypeTag::DOUBLE_TAG:
    case TypeTag::LARGE_INTEGER_TAG:
    case TypeTag::BYTE_ARRAY_TAG:
    case TypeTag::FREE_LIST_REGION_TAG:
    case TypeTag::SINGLE_FREE_WORD_TAG:
      // No roots.
      break;
    case TypeTag::PROMOTED_TRACK_TAG:
      // Normally do nothing for these.
      break;
    default:
      FATAL("Unexpected class tag");
  }
}

void HeapObject::_set_header(Program* program, Smi* id) {
  TypeTag tag = program->class_tag_for(id);
  _set_header(id, tag);
}

FreeListRegion* FreeListRegion::create_at(uword start, uword size) {
  if (size >= MINIMUM_SIZE) {
    auto self = reinterpret_cast<FreeListRegion*>(HeapObject::from_address(start));
    self->_set_header(Smi::from(FREE_LIST_REGION_CLASS_ID), FREE_LIST_REGION_TAG);
    self->_word_at_put(SIZE_OFFSET, size);
    self->_at_put(NEXT_OFFSET, null);
    return self;
  }
  for (uword i = 0; i < size; i += WORD_SIZE) {
    auto one_word = reinterpret_cast<FreeListRegion*>(HeapObject::from_address(start + i));
    one_word->_set_header(Smi::from(SINGLE_FREE_WORD_CLASS_ID), SINGLE_FREE_WORD_TAG);
  }
  return null;
}

Object* FreeListRegion::single_free_word_header() {
  uword header = SINGLE_FREE_WORD_CLASS_ID;
  header = (header << CLASS_ID_OFFSET) | SINGLE_FREE_WORD_TAG;
  return Smi::from(header);
}

bool HeapObject::is_a_free_object() {
  int tag = class_tag();
  if (tag == FREE_LIST_REGION_TAG) {
    ASSERT(Smi::value(class_id()) == FREE_LIST_REGION_CLASS_ID);
    return true;
  }
  if (tag == SINGLE_FREE_WORD_TAG) {
    ASSERT(Smi::value(class_id()) == SINGLE_FREE_WORD_CLASS_ID);
    return true;
  }
  return false;
}

class PointerRootCallback : public RootCallback {
 public:
  explicit PointerRootCallback(PointerCallback* callback) : callback(callback) {}
  void do_roots(Object** roots, word length) {
    for (word i = 0; i < length; i++) {
      callback->object_address(&roots[i]);
    }
  }
  PointerCallback* callback;
};

void HeapObject::do_pointers(Program* program, PointerCallback* cb) {
  if (has_class_tag(BYTE_ARRAY_TAG)) {
    auto byte_array = ByteArray::cast(this);
    byte_array->do_pointers(cb);
  } else if (has_class_tag(STRING_TAG)) {
    auto str = String::cast(this);
    str->do_pointers(cb);
  } else {
    // All other object's pointers are covered by doing their roots.
    PointerRootCallback root_callback(cb);
    roots_do(program, &root_callback);
  }
}

bool HeapObject::can_be_toit_finalized(Program* program) const {
  auto tag = class_tag();
  if (tag != INSTANCE_TAG) return false;
  // Some instances are banned for Toit finalizers.  These are typically
  // things like string slices, which are implemented as special instances,
  // but don't have identity.  We reuse the byte_content function to check
  // this.
  const uint8* dummy1;
  word dummy2;
  if (byte_content(program, &dummy1, &dummy2, STRINGS_OR_BYTE_ARRAYS)) {
    // Can't finalize strings and byte arrays.  This is partly because it
    // doesn't make sense, but also because we only have one finalizer bit in
    // the header, and it's also for VM finalizers, that free external memory.
    return false;
  }
  if (is_instance(this) && class_id() == program->map_class_id()) {
    // Can't finalize maps, because we use the finalize bit in the header to
    // mark weak maps.
    return false;
  }
  return true;
}

void ByteArray::do_pointers(PointerCallback* cb) {
  if (has_external_address()) {
    cb->c_address(reinterpret_cast<void**>(_raw_at(EXTERNAL_ADDRESS_OFFSET)));
  }
}

void String::do_pointers(PointerCallback* cb) {
  if (!content_on_heap()) {
    cb->c_address(reinterpret_cast<void**>(_raw_at(EXTERNAL_ADDRESS_OFFSET)));
  }
}

void Array::roots_do(RootCallback* cb) {
  cb->do_roots(_root_at(_offset_from(0)), length());
}

word Stack::absolute_bci_at_preemption(Program* program) {
  // Check that the stack has both words.
  if (_stack_sp_addr() + 1 >= _stack_base_addr()) return -1;
  // Check that the frame marker is correct.
  if (at(0) != program->frame_marker()) return -1;
  // Get the bytecode pointer and convert it to an index.
  uint8* bcp = reinterpret_cast<uint8*>(at(1));
  if (!program->bytecodes.is_inside(bcp)) return -1;
  return program->absolute_bci_from_bcp(bcp);
}

void Stack::roots_do(Program* program, RootCallback* cb) {
  if (is_guard_zone_touched()) FATAL("stack overflow detected");
  word top = this->top();
  ASSERT(top >= 0);
  ASSERT(top <= length());
  // Skip over pointers into the bytecodes.
  void* bytecodes_from = program->bytecodes.data();
  void* bytecodes_to = &program->bytecodes.data()[program->bytecodes.length()];
  // Assert that the frame-marker is skipped this way as well.
  ASSERT(bytecodes_from <= program->frame_marker() && program->frame_marker() < bytecodes_to);
  // The stack overflow check happens on function entry, so we can't shrink the
  // stack so much that an overflow check would have failed.  Luckily the
  // compiler kept track of the maximum space that any function could need, so
  // we can use that.
  word minimum_space = program->global_max_stack_height() + RESERVED_STACK_FOR_CALLS;
  // Don't shrink the stack unless we can halve the size.  The growing algo
  // grows it by 50%, to try to avoid too much churn.
  if (top > minimum_space && (Flags::shrink_stacks_a_lot || (cb->shrink_stacks() && top > length() >> 1))) {
    word reduction = top - minimum_space;
    if (Flags::shrink_stacks_a_lot || reduction >= 8) {
      auto destin = _array_address(0);
      auto source = _array_address(reduction);
      memmove(destin, source, (length() - reduction) << WORD_SIZE_LOG_2);
      // We don't need to update the remembered set/write barrier because the
      // start of the stack object has not moved.
      word len = length() - reduction;
      top -= reduction;
      _set_length(len);
      _set_top(top);
      _set_try_top(try_top() - reduction);
      // Now that the stack is smaller we need to fill the space after it with
      // something to keep the heap iterable.
      for (word i = 0; i < reduction; i++) {
        auto one_word = static_cast<FreeListRegion*>(HeapObject::cast(_array_address(len + i)));
        one_word->_set_header(Smi::from(SINGLE_FREE_WORD_CLASS_ID), SINGLE_FREE_WORD_TAG);
      }
    }
  }
  Object** roots = _root_at(_array_offset_from(top));
  word used_length = length() - top;
  for (word i = 0; i < used_length; i++) {
    Object* root_object = roots[i];
    if (bytecodes_from <= root_object && root_object < bytecodes_to) continue;
    cb->do_root(&roots[i]);
  }
}

int Stack::frames_do(Program* program, FrameCallback* cb) {
  word stack_length = _stack_base_addr() - _stack_sp_addr();
  word frame_no = 0;
  // The last return address we encountered. Represents the location inside the
  // method that is currently on the frame.
  uint8* last_return_bcp = null;
  bool is_first_frame = true;
  for (word index = 0; index < stack_length - 1; index++) {
    Object* probe = at(index);
    if (probe != program->frame_marker()) continue;
    uint8* return_bcp = reinterpret_cast<uint8*>(at(index + 1));
    if (last_return_bcp == null) {
      // Drop the primitive call.
      ASSERT(frame_no == 0);
    } else if (is_first_frame) {
      // Don't report the `throw` frame.
      is_first_frame = false;
    } else {
      cb->do_frame(this, frame_no, program->absolute_bci_from_bcp(last_return_bcp));
      frame_no++;
    }
    last_return_bcp = return_bcp;
  }
  return frame_no;
}

void Instance::instance_roots_do(word instance_size, RootCallback* cb) {
  if (has_active_finalizer() && cb->skip_marking(this)) return;
  word fields = fields_from_size(instance_size);
  cb->do_roots(_root_at(_offset_from(0)), fields);
}

bool Object::encode_on(ProgramOrientedEncoder* encoder) {
  return encoder->encode(this);
}

bool String::starts_with_vowel() {
  Bytes bytes(this);
  word len = bytes.length();
  word pos = 0;
  while (pos < len && bytes.at(pos) == '_') pos++;
  if (pos == len) return false;
  return strchr("aeiouAEIOU", bytes.at(pos)) != null;
}

uint16 String::compute_hash_code() {
  Bytes bytes(this);
  return compute_hash_code_for(reinterpret_cast<const char*>(bytes.address()), bytes.length());
}

uint16 String::compute_hash_code_for(const char* str) {
  return compute_hash_code_for(str, strlen(str));
}

uint16 String::compute_hash_code_for(const char* str, word str_len) {
  // Trivial computation of hash code for string.
  uint16 hash = str_len;
  for (word index = 0; index < str_len; index++) {
    // The sign of 'char' is implementation dependent.
    // Force the value to be unsigned to have a deterministic hash.
    hash = 31 * hash + static_cast<uint8>(str[index]);
  }
  return hash != NO_HASH_CODE ? hash : 0;
}

uint16 String::_assign_hash_code() {
  _raw_set_hash_code(compute_hash_code());
  ASSERT(_raw_hash_code() != NO_HASH_CODE);
  ASSERT(_is_valid_utf8());
  return _raw_hash_code();
}

char* String::cstr_dup() {
  Bytes bytes(this);
  word len = bytes.length();
  char* buffer = unvoid_cast<char*>(malloc(len + 1));
  if (!buffer) return null;
  memcpy(buffer, bytes.address(), len + 1);
  return buffer;
}

bool String::equals(Object* other) {
  if (this == other) return true;
  if (!is_string(other)) return false;
  String* other_string = String::cast(other);
  if (hash_code() != other_string->hash_code()) return false;
  Bytes bytes(this);
  Bytes other_bytes(other_string);
  return slow_equals(bytes.address(), bytes.length(), other_bytes.address(), other_bytes.length());
}

int String::compare(String* other) {
  if (this == other) return 0;
  Bytes bytes(this);
  Bytes other_bytes(other);
  return compare(bytes.address(), bytes.length(), other_bytes.address(), other_bytes.length());
}

bool String::slow_equals(const char* other) {
  return slow_equals(other, strlen(other));
}

bool String::slow_equals(const char* other, word other_length) {
  Bytes bytes(this);
  return slow_equals(reinterpret_cast<const char*>(bytes.address()), bytes.length(), other, other_length);
}

bool String::_is_valid_utf8() {
  Bytes content(this);
  return Utils::is_valid_utf_8(content.address(), content.length());
}

void PromotedTrack::zap() {
  uword header = SINGLE_FREE_WORD_CLASS_ID;
  header = (header << CLASS_ID_OFFSET) | SINGLE_FREE_WORD_TAG;
  Object* filler = Smi::from(header);
  for (uword p = _raw(); p < _raw() + HEADER_SIZE; p += WORD_SIZE) {
    *reinterpret_cast<Object**>(p) = filler;
  }
}

#ifndef TOIT_FREERTOS

void Array::write_content(SnapshotWriter* st) {
  word len = length();
  for (word index = 0; index < len; index++) st->write_object(at(index));
}

void ByteArray::write_content(SnapshotWriter* st) {
  Bytes bytes(this);
  if (bytes.length() > SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    if (has_external_address() && external_tag() != RawByteTag) {
      FATAL("Can only serialize raw bytes");
    }
    st->write_external_list_uint8(List<const uint8>(bytes.address(), bytes.length()));
  } else {
    for (word index = 0; index < bytes.length(); index++) {
      st->write_cardinal(bytes.at(index));
    }
  }
}

void Instance::write_content(word instance_size, SnapshotWriter* st) {
  word fields = fields_from_size(instance_size);
  st->write_cardinal(fields);
  for (word index = 0; index < fields; index++) {
    st->write_object(at(index));
  }
}

void String::write_content(SnapshotWriter* st) {
  Bytes bytes(this);
  word len = bytes.length();
  if (len > String::SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    // TODO(florian): we should remove the '\0'.
    st->write_external_list_uint8(List<const uint8>(bytes.address(), bytes.length() + 1));
  } else {
    ASSERT(content_on_heap());
    for (word index = 0; index < len; index++) st->write_byte(bytes.at(index));
  }
}

void Double::write_content(SnapshotWriter* st) {
  st->write_double(value());
}

void Instance::read_content(SnapshotReader* st) {
  word len = st->read_cardinal();
  for (word index = 0; index < len; index++) {
    // Only used to read snapshots onto the program heap, which has no write barrier.
    at_put_no_write_barrier(index, st->read_object());
  }
}

void String::read_content(SnapshotReader* st, word len) {
  if (len > String::SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    _set_external_length(len);
    auto external_bytes = st->read_external_list_uint8();
    ASSERT(external_bytes.length() == len + 1);  // TODO(florian): we shouldn't have a '\0'.
    _set_external_address(external_bytes.data());
    _assign_hash_code();
  } else {
    _set_length(len);
    MutableBytes bytes(this);
    for (word index = 0; index < len; index++) bytes._at_put(index, st->read_byte());
    bytes._set_end();
    _assign_hash_code();
    ASSERT(content_on_heap());
  }
}

void Double::read_content(SnapshotReader* st) {
  _set_value(st->read_double());
}

void Array::read_content(SnapshotReader* st, word len) {
  _set_length(len);
  // Only used to read snapshots onto the program heap, which has no write barrier.
  for (word index = 0; index < len; index++) at_put_no_write_barrier(index, st->read_object());
}

void ByteArray::read_content(SnapshotReader* st, word len) {
  if (len > SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    _set_external_length(len);
    auto external_bytes = st->read_external_list_uint8();
    ASSERT(external_bytes.length() == len);
    _set_external_tag(RawByteTag);
    _set_external_address(external_bytes.data());
  } else {
    _set_length(len);
    Bytes bytes(this);

    for (word index = 0; index < len; index++)
      bytes.at_put(index, st->read_cardinal());
  }
}

#endif  // TOIT_FREERTOS

word ByteArray::max_internal_size() {
  return Utils::max(max_internal_size_in_process(), max_internal_size_in_program());
}

word String::max_internal_size() {
  return Utils::max(max_internal_size_in_process(), max_internal_size_in_program());
}

}  // namespace toit
