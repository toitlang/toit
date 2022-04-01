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

bool Object::byte_content(Program* program, const uint8** content, int* length, BlobKind strings_only) {
  if (is_string()) {
    String::Bytes bytes(String::cast(this));
    *length = bytes.length();
    *content = bytes.address();
    return true;
  }
  if (strings_only == STRINGS_OR_BYTE_ARRAYS && is_byte_array()) {
    ByteArray* byte_array = ByteArray::cast(this);
    // External byte arrays can have structs in them. This is captured in the external tag.
    // We only allow extracting the byte content from an external byte arrays iff it is tagged with RawByteType.
    if (byte_array->has_external_address() && byte_array->external_tag() != RawByteTag) return false;
    ByteArray::Bytes bytes(byte_array);
    *length = bytes.length();
    *content = bytes.address();
    return true;
  }
  if (is_instance()) {
    auto instance = Instance::cast(this);
    auto class_id = instance->class_id();
    if (strings_only == STRINGS_OR_BYTE_ARRAYS && class_id == program->byte_array_cow_class_id()) {
      auto backing = instance->at(0);
      return backing->byte_content(program, content, length, strings_only);
    } else if ((strings_only == STRINGS_OR_BYTE_ARRAYS && class_id == program->byte_array_slice_class_id()) || class_id == program->string_slice_class_id()) {
      auto wrapped = instance->at(0);
      auto from = instance->at(1);
      auto to = instance->at(2);
      if (!wrapped->is_heap_object()) return false;
      // TODO(florian): we could eventually accept larger integers here.
      if (!from->is_smi()) return false;
      if (!to->is_smi()) return false;
      int from_value = Smi::cast(from)->value();
      int to_value = Smi::cast(to)->value();
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

bool Object::byte_content(Program* program, Blob* blob, BlobKind strings_only) {
  const uint8* content = null;
  int length = 0;
  bool result = byte_content(program, &content, &length, strings_only);
  *blob = Blob(content, length);
  return result;
}

bool Blob::slow_equals(const char* c_string) const {
  if (static_cast<size_t>(length()) != strlen(c_string)) return false;
  return memcmp(address(), c_string, length()) == 0;
}

int HeapObject::size(Program* program) {
  int size = program->instance_size_for(this);
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
      Instance::cast(this)->roots_do(program->instance_size_for(this), cb);
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

class PointerRootCallback : public RootCallback {
 public:
  explicit PointerRootCallback(PointerCallback* callback) : callback(callback) {}
  void do_roots(Object** roots, int length) {
    for (int i = 0; i < length; i++) {
      callback->object_address(&roots[i]);
    }
  }
  PointerCallback* callback;
};

void HeapObject::do_pointers(Program* program, PointerCallback* cb) {
  if (class_tag() == BYTE_ARRAY_TAG) {
    auto byte_array = ByteArray::cast(this);
    byte_array->do_pointers(cb);
  } else if (class_tag() == STRING_TAG) {
    auto str = String::cast(this);
    str->do_pointers(cb);
  } else {
    // All other object's pointers are covered by doing their roots.
    PointerRootCallback root_callback(cb);
    roots_do(program, &root_callback);
  }
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

void Stack::roots_do(Program* program, RootCallback* cb) {
  int top = this->top();
  // Skip over pointers into the bytecodes.
  void* bytecodes_from = program->bytecodes.data();
  void* bytecodes_to = &program->bytecodes.data()[program->bytecodes.length()];
  // Assert that the frame-marker is skipped this way as well.
  ASSERT(bytecodes_from <= program->frame_marker() && program->frame_marker() < bytecodes_to);
  Object** roots = _root_at(_array_offset_from(top));
  int used_length = length() - top;
  for (int i = 0; i < used_length; i++) {
    Object* root_object = roots[i];
    if (bytecodes_from <= root_object && root_object < bytecodes_to) continue;
    cb->do_root(&roots[i]);
  }
}

int Stack::frames_do(Program* program, FrameCallback* cb) {
  int stack_length = _stack_base_addr() - _stack_sp_addr();
  int frame_no = 0;
  // The last return address we encountered. Represents the location inside the
  //   method that is currently on the frame.
  uint8* last_return_bcp = null;
  bool is_first_frame = true;
  for (int index = 0; index < stack_length - 1; index++) {
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

void Stack::copy_to(HeapObject* other, int other_length) {
  other->_at_put(HeapObject::HEADER_OFFSET, _at(HeapObject::HEADER_OFFSET));
  Stack* to = Stack::cast(other);
  int used = length() - top();
  ASSERT(other_length >= used);
  int displacement = other_length - length();
  memcpy(to->_array_address(top() + displacement), _array_address(top()), used * WORD_SIZE);
  to->_at_put(TASK_OFFSET, _at(TASK_OFFSET));
  to->_set_length(other_length);
  to->_set_top(displacement + top());
  to->_set_try_top(displacement + try_top());
  to->_set_in_stack_overflow(in_stack_overflow());
}

void Instance::roots_do(int instance_size, RootCallback* cb) {
  int len = length_from_size(instance_size);
  cb->do_roots(_root_at(_offset_from(0)), len);
}

bool Object::encode_on(ProgramOrientedEncoder* encoder) {
  return encoder->encode(this);
}

void Stack::transfer_to_interpreter(Interpreter* interpreter) {
  ASSERT(top() > 0);
  ASSERT(top() <= length());
  interpreter->_limit = _stack_limit_addr();
  interpreter->_base = _stack_base_addr();
  interpreter->_sp = _stack_sp_addr();
  interpreter->_try_sp = _stack_try_sp_addr();
  interpreter->_in_stack_overflow = in_stack_overflow();
  ASSERT(top() == (interpreter->_sp - _stack_limit_addr()));
  _set_top(-1);
}

void Stack::transfer_from_interpreter(Interpreter* interpreter) {
  ASSERT(top() == -1);
  _set_top(interpreter->_sp - _stack_limit_addr());
  _set_try_top(interpreter->_try_sp - _stack_limit_addr());
  _set_in_stack_overflow(interpreter->_in_stack_overflow);
  ASSERT(top() > 0 && top() <= length());
}

bool String::starts_with_vowel() {
  Bytes bytes(this);
  int len = bytes.length();
  int pos = 0;
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

uint16 String::compute_hash_code_for(const char* str, int str_len) {
  // Trivial computation of hash code for string.
  uint16 hash = str_len;
  for (int index = 0; index < str_len; index++) {
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
  int len = bytes.length();
  char* buffer = unvoid_cast<char*>(malloc(len + 1));
  if (!buffer) return null;
  memcpy(buffer, bytes.address(), len + 1);
  return buffer;
}

bool String::equals(Object* other) {
  if (this == other) return true;
  if (!other->is_string()) return false;
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

bool String::slow_equals(const char* other, int other_length) {
  Bytes bytes(this);
  return slow_equals(reinterpret_cast<const char*>(bytes.address()), bytes.length(), other, other_length);
}

bool String::_is_valid_utf8() {
  Bytes content(this);
  return Utils::is_valid_utf_8(content.address(), content.length());
}

void PromotedTrack::zap() {
  uword header = SINGLE_FREE_WORD_CLASS_ID;
  header = (header << CLASS_TAG_BIT_SIZE) | SINGLE_FREE_WORD_TAG;
  Object* filler = Smi::from(header);
  for (uword p = _raw(); p < _raw() + HEADER_SIZE; p += WORD_SIZE) {
    *reinterpret_cast<Object**>(p) = filler;
  }
}

PromotedTrack* PromotedTrack::initialize(PromotedTrack* next, uword location, uword end) {
  ASSERT(end - location > header_size());
  auto self = reinterpret_cast<PromotedTrack*>(HeapObject::from_address(location));
  self->_set_header(Smi::from(PROMOTED_TRACK_CLASS_ID), PROMOTED_TRACK_TAG);
  self->_at_put(NEXT_OFFSET, next);
  self->_word_at_put(END_OFFSET, end);
  return self;
}

#ifndef TOIT_FREERTOS

void Array::write_content(SnapshotWriter* st) {
  int len = length();
  for (int index = 0; index < len; index++) st->write_object(at(index));
}

void ByteArray::write_content(SnapshotWriter* st) {
  Bytes bytes(this);
  if (bytes.length() > SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    if (has_external_address() && external_tag() != RawByteTag) {
      FATAL("Can only serialize raw bytes");
    }
    st->write_external_list_uint8(List<uint8>(bytes.address(), bytes.length()));
  } else {
    for (int index = 0; index < bytes.length(); index++) {
      st->write_cardinal(bytes.at(index));
    }
  }
}

void Instance::write_content(int instance_size, SnapshotWriter* st) {
  int len = length_from_size(instance_size);
  st->write_cardinal(len);
  for (int index = 0; index < len; index++) {
    st->write_object(at(index));
  }
}

void String::write_content(SnapshotWriter* st) {
  Bytes bytes(this);
  int len = bytes.length();
  if (len > String::SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    // TODO(florian): we should remove the '\0'.
    st->write_external_list_uint8(List<uint8>(bytes.address(), bytes.length() + 1));
  } else {
    ASSERT(content_on_heap());
    for (int index = 0; index < len; index++) st->write_byte(bytes.at(index));
  }
}

void Double::write_content(SnapshotWriter* st) {
  st->write_double(value());
}

void Instance::read_content(SnapshotReader* st) {
  int len = st->read_cardinal();
  for (int index = 0; index < len; index++) {
    at_put(index, st->read_object());
  }
}

void String::read_content(SnapshotReader* st, int len) {
  if (len > String::SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    _set_external_length(len);
    auto external_bytes = st->read_external_list_uint8();
    ASSERT(external_bytes.length() == len + 1);  // TODO(florian): we shouldn't have a '\0'.
    _set_external_address(external_bytes.data());
  } else {
    _set_length(len);
    Bytes bytes(this);
    for (int index = 0; index < len; index++) bytes._at_put(index, st->read_byte());
    bytes._set_end();
    _assign_hash_code();
    ASSERT(content_on_heap());
  }
}

void Double::read_content(SnapshotReader* st) {
  _set_value(st->read_double());
}

void Array::read_content(SnapshotReader* st, int len) {
  _set_length(len);
  for (int index = 0; index < len; index++) at_put(index, st->read_object());
}

void ByteArray::read_content(SnapshotReader* st, int len) {
  if (len > SNAPSHOT_INTERNAL_SIZE_CUTOFF) {
    _set_external_length(len);
    auto external_bytes = st->read_external_list_uint8();
    ASSERT(external_bytes.length() == len);
    _set_external_tag(RawByteTag);
    _set_external_address(external_bytes.data());
  } else {
    _set_length(len);
    Bytes bytes(this);

    for (int index = 0; index < len; index++)
      bytes.at_put(index, st->read_cardinal());
  }
}

word ByteArray::max_internal_size() {
  return Utils::max(max_internal_size_in_process(), max_internal_size_in_program());
}

word String::max_internal_size() {
  return Utils::max(max_internal_size_in_process(), max_internal_size_in_program());
}

#endif  // TOIT_FREERTOS

}  // namespace toit
