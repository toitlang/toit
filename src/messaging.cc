// Copyright (C) 2022 Toitware ApS.
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

#include "messaging.h"

#include "objects.h"
#include "process.h"

namespace toit {

enum MessageTag {
  TAG_POSITIVE_SMI,
  TAG_NEGATIVE_SMI,
  TAG_NULL,
  TAG_TRUE,
  TAG_FALSE,
  TAG_STRING,
  TAG_ARRAY,
  TAG_BYTE_ARRAY,
  TAG_DOUBLE,
  TAG_LARGE_INTEGER,
};

class NestingTracker {
 public:
  NestingTracker(int* nesting) : _nesting(nesting) {
    (*nesting)++;
  }

  ~NestingTracker() {
    (*_nesting)--;
  }

 private:
  int* _nesting;
};

MessageEncoder::MessageEncoder(Process* process, uint8* buffer)
    : _process(process)
    , _program(process ? process->program() : null)
    , _buffer(buffer)
    , _cursor(0)
    , _nesting(0)
    , _malloc_failed(false)
    , _copied_count(0)
    , _externals_count(0) {
}

void MessageEncoder::encode_termination_message(uint8* buffer, uint8 value) {
  MessageEncoder encoder(null, buffer);
  encoder.encode(Smi::from(value));
  ASSERT(encoder.size() <= MESSAGING_TERMINATION_MESSAGE_SIZE);
}

void MessageEncoder::free_copied() {
  for (unsigned i = 0; i < _copied_count; i++) {
    free(_copied[i]);
  }
}

void MessageEncoder::neuter_externals() {
  for (unsigned i = 0; i < _externals_count; i++) {
    _externals[i]->neuter(_process);
  }
}

bool MessageEncoder::encode(Object* object) {
  NestingTracker tracking(&_nesting);
  if (_nesting > MESSAGING_ENCODING_MAX_NESTING) {
    printf("[message encoder: too much nesting %d]\n", _nesting);
    return false;
  }

  if (object->is_smi()) {
    word value = Smi::cast(object)->value();
    if (value >= 0) {
      write_uint8(TAG_POSITIVE_SMI);
      write_cardinal(value);
    } else {
      write_uint8(TAG_NEGATIVE_SMI);
      write_cardinal(-value);
    }
    return true;
  } else if (object->is_instance()) {
    Instance* instance = Instance::cast(object);
    Smi* class_id = instance->class_id();
    if (class_id == _program->list_class_id()) {
      Object* backing = instance->at(0);
      if (backing->is_array()) {
        Array* array = Array::cast(backing);
        return encode_array(array, Smi::cast(instance->at(1))->value());
      }
    }
    printf("[message encoder: cannot encode instance with class id = %ld]\n", class_id->value());
  } else if (object == _program->null_object()) {
    write_uint8(TAG_NULL);
    return true;
  } else if (object == _program->true_object()) {
    write_uint8(TAG_TRUE);
    return true;
  } else if (object == _program->false_object()) {
    write_uint8(TAG_FALSE);
    return true;
  } else if (object->is_byte_array()) {
    return encode_byte_array(ByteArray::cast(object));
  } else if (object->is_double()) {
    write_uint8(TAG_DOUBLE);
    write_uint64(bit_cast<uint64>(Double::cast(object)->value()));
    return true;
  } else if (object->is_string()) {
    return encode_string(String::cast(object));
  } else if (object->is_array()) {
    Array* array = Array::cast(object);
    return encode_array(array, array->length());
  } else if (object->is_large_integer()) {
    write_uint8(TAG_LARGE_INTEGER);
    write_uint64(bit_cast<uint64>(Double::cast(object)->value()));
    return true;
  } else if (object->is_heap_object()) {
    printf("[message encoder: cannot encode object with class tag = %d]\n", HeapObject::cast(object)->class_tag());
  }
  return false;
}

bool MessageEncoder::encode_string(String* object) {
  return encode_copy(object, TAG_STRING);
}

bool MessageEncoder::encode_array(Array* object, int size) {
  write_uint8(TAG_ARRAY);
  write_cardinal(size);
  for (int i = 0; i < size; i++) {
    if (!encode(object->at(i))) return false;
  }
  return true;
}

bool MessageEncoder::encode_byte_array(ByteArray* object) {
  if (!object->has_external_address()) {
    return encode_copy(object, TAG_BYTE_ARRAY);
  }

  ByteArray::Bytes bytes(object);
  write_uint8(TAG_BYTE_ARRAY);
  write_cardinal(bytes.length());
  write_pointer(bytes.address());
  if (!encoding_for_size()) {
    if (_externals_count >= ARRAY_SIZE(_externals)) {
      // TODO(kasper): Report meaningful error.
      return false;
    }
    _externals[_externals_count++] = object;
  }
  return true;
}

bool MessageEncoder::encode_copy(Object* object, int tag) {
  const uint8* source;
  int length = 0;
  void* data = null;
  if (!object->byte_content(_program, &source, &length, STRINGS_OR_BYTE_ARRAYS)) {
    // TODO(kasper): Report meaningful error.
    return false;
  }
  if (!encoding_for_size()) {
    data = malloc(length);
    if (data == null) {
      _malloc_failed = true;
      return false;
    }
    if (_copied_count >= ARRAY_SIZE(_copied)) {
      // TODO(kasper): Report meaningful error.
      return false;
    }
    _copied[_copied_count++] = data;
    memcpy(data, source, length);
  }
  write_uint8(tag);
  write_cardinal(length);
  write_pointer(data);
  return true;
}

void MessageEncoder::write_pointer(void* value) {
  if (!encoding_for_size()) memcpy(&_buffer[_cursor], &value, WORD_SIZE);
  _cursor += WORD_SIZE;
}

void MessageEncoder::write_cardinal(uword value) {
  while (value >= 128) {
    write_uint8((uint8) (value % 128 + 128));
    value >>= 7;
  }
  write_uint8((uint8) value);
}

void MessageEncoder::write_uint64(uint64 value) {
  if (!encoding_for_size()) memcpy(&_buffer[_cursor], &value, sizeof(uint64));
  _cursor += sizeof(uint64);
}

MessageDecoder::MessageDecoder(Process* process, uint8* buffer)
    : _process(process)
    , _program(process ? process->program() : null)
    , _buffer(buffer)
    , _cursor(0)
    , _allocation_failed(false)
    , _external_allocations(0)
    , _externals_count(0) {
}

bool MessageDecoder::decode_termination_message(uint8* buffer, int* value) {
  MessageDecoder decoder(null, buffer);
  // TODO(kasper): Make this more robust. We don't know the content.
  Object* object = decoder.decode();
  if (object->is_smi()) {
    *value = Smi::cast(object)->value();
    return true;
  }
  return false;
}

void MessageDecoder::remove_disposing_finalizers() {
  for (unsigned i = 0; i < _externals_count; i++) {
    _process->object_heap()->remove_finalizer(_externals[i]);
  }
}

void MessageDecoder::register_external(HeapObject* object, int length) {
  if (_externals_count >= ARRAY_SIZE(_externals)) {
    FATAL("[message decoder: too many externals: %d]", _externals_count + 1);
  }
  _externals[_externals_count++] = object;
  _external_allocations += length;
}

Object* MessageDecoder::decode() {
  int tag = read_uint8();
  switch (tag) {
    case TAG_POSITIVE_SMI:
      return Smi::from(read_cardinal());
    case TAG_NEGATIVE_SMI:
      return Smi::from(-static_cast<word>(read_cardinal()));
    case TAG_NULL:
      return _program->null_object();
    case TAG_TRUE:
      return _program->true_object();
    case TAG_FALSE:
      return _program->false_object();
    case TAG_STRING:
      return decode_string();
    case TAG_ARRAY:
      return decode_array();
    case TAG_BYTE_ARRAY:
      return decode_byte_array();
    case TAG_DOUBLE:
      return decode_double();
    case TAG_LARGE_INTEGER:
      return decode_large_integer();
    default:
      FATAL("[message decoder: unhandled message tag: %d]", tag);
  }
  return null;
}

Object* MessageDecoder::decode_string() {
  int length = read_cardinal();
  uint8* data = read_pointer();
  String* result = _process->object_heap()->allocate_external_string(length, data, true);
  if (result == null) {
    _allocation_failed = true;
    return null;
  }
  register_external(result, length + 1);  // Account for '\0'-termination.
  return result;
}

Object* MessageDecoder::decode_array() {
  int length = read_cardinal();
  Array* result = _process->object_heap()->allocate_array(length);
  if (result == null) {
    _allocation_failed = true;
    return null;
  }
  for (int i = 0; i < length; i++) {
    Object* inner = decode();
    if (_allocation_failed) return null;
    result->at_put(i, inner);
  }
  return result;
}

Object* MessageDecoder::decode_byte_array() {
  int length = read_cardinal();
  uint8* data = read_pointer();
  ByteArray* result = _process->object_heap()->allocate_external_byte_array(length, data, true, false);
  if (result == null) {
    _allocation_failed = true;
    return null;
  }
  register_external(result, length);
  return result;
}

Object* MessageDecoder::decode_double() {
  double value = bit_cast<double>(read_uint64());
  Double* result = _process->object_heap()->allocate_double(value);
  if (result == null) {
    _allocation_failed = true;
    return null;
  }
  return result;
}

Object* MessageDecoder::decode_large_integer() {
  int64 value = read_uint64();
  LargeInteger* result = _process->object_heap()->allocate_large_integer(value);
  if (result == null) {
    _allocation_failed = true;
    return null;
  }
  return result;
}

uint8* MessageDecoder::read_pointer() {
  uint8* result;
  memcpy(&result, &_buffer[_cursor], WORD_SIZE);
  _cursor += WORD_SIZE;
  return result;
}

uword MessageDecoder::read_cardinal() {
  uword result = 0;
  uint8 byte = read_uint8();
  int shift = 0;
  while (byte >= 128) {
    result += (((uword) byte) - 128) << shift;
    shift += 7;
    byte = read_uint8();
  }
  result += ((uword) byte) << shift;
  return result;
}

uint64 MessageDecoder::read_uint64() {
  uint64 result;
  memcpy(&result, &_buffer[_cursor], sizeof(uint64));
  _cursor += WORD_SIZE;
  return result;
}

}  // namespace toit
