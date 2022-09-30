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
#include "scheduler.h"
#include "vm.h"

#include "objects_inline.h"

namespace toit {

enum MessageTag {
  TAG_POSITIVE_SMI,
  TAG_NEGATIVE_SMI,
  TAG_NULL,
  TAG_TRUE,
  TAG_FALSE,
  TAG_ARRAY,
  TAG_DOUBLE,
  TAG_LARGE_INTEGER,
  TAG_MAP,

  // MessageEncoder::encode_copy() relies on the fact that 'inline' tags
  // for strings and byte arrays directly follow their non-inline variants.
  TAG_STRING,
  TAG_STRING_INLINE,
  TAG_BYTE_ARRAY,
  TAG_BYTE_ARRAY_INLINE,
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

void SystemMessage::free_data_and_externals() {
  MessageDecoder::deallocate(_data);
  _data = null;
}

MessageEncoder::MessageEncoder(Process* process, uint8* buffer, bool flatten)
    : _process(process)
    , _program(process ? process->program() : null)
    , _flatten(flatten)
    , _buffer(buffer) {
}

void MessageEncoder::encode_process_message(uint8* buffer, uint8 value) {
  MessageEncoder encoder(null, buffer);
  encoder.encode(Smi::from(value));
  ASSERT(encoder.size() <= MESSAGING_PROCESS_MESSAGE_SIZE);
}

void MessageEncoder::free_copied() {
  for (unsigned i = 0; i < _copied_count; i++) {
    free(_copied[i]);
  }
}

void MessageEncoder::neuter_externals() {
  ObjectHeap* heap = _process->object_heap();
  for (unsigned i = 0; i < _externals_count; i++) {
    ByteArray* array = _externals[i];
    // Neuter the byte array. The contents of the array is now linked to from
    // an enqueued SystemMessage and will be used to construct a new external
    // byte array in the receiving process.
    array->neuter(_process);

    // Optimization: Eagerly remove any disposing finalizer, so the garbage
    // collector does not have to deal with disposing a neutered byte array.
    heap->remove_vm_finalizer(array);
  }
}

bool MessageEncoder::encode(Object* object) {
  NestingTracker tracking(&_nesting);
  if (_nesting > MESSAGING_ENCODING_MAX_NESTING) {
    printf("[message encoder: too much nesting %d]\n", _nesting);
    return false;
  }

  if (is_smi(object)) {
    word value = Smi::cast(object)->value();
    if (value >= 0) {
      write_uint8(TAG_POSITIVE_SMI);
      write_cardinal(value);
    } else {
      write_uint8(TAG_NEGATIVE_SMI);
      write_cardinal(-value);
    }
    return true;
  } else if (is_instance(object)) {
    Instance* instance = Instance::cast(object);
    Smi* class_id = instance->class_id();
    if (class_id == _program->list_class_id()) {
      Object* backing = instance->at(Instance::LIST_ARRAY_INDEX);
      if (is_smi(backing)) return false;
      class_id = HeapObject::cast(backing)->class_id();
      if (class_id == _program->array_class_id()) {
        Array* array = Array::cast(backing);
        Object* size = instance->at(Instance::LIST_SIZE_INDEX);
        if (!is_smi(size)) return false;
        return encode_array(array, Smi::cast(size)->value());
      } else if (class_id == _program->large_array_class_id()) {
        printf("[message encoder: cannot encode large array]\n");
      }
    } else if (class_id == _program->map_class_id()) {
      return encode_map(instance);
    } else if (class_id == _program->byte_array_cow_class_id()) {
      return encode_copy(object, TAG_BYTE_ARRAY);
    } else if (class_id == _program->byte_array_slice_class_id()) {
      return encode_copy(object, TAG_BYTE_ARRAY);
    } else if (class_id == _program->string_slice_class_id()) {
      return encode_copy(object, TAG_STRING);
    }
    printf("[message encoder: cannot encode instance with class id = %zd]\n", class_id->value());
  } else if (object == _program->null_object()) {
    write_uint8(TAG_NULL);
    return true;
  } else if (object == _program->true_object()) {
    write_uint8(TAG_TRUE);
    return true;
  } else if (object == _program->false_object()) {
    write_uint8(TAG_FALSE);
    return true;
  } else if (is_byte_array(object)) {
    return encode_byte_array(ByteArray::cast(object));
  } else if (is_double(object)) {
    write_uint8(TAG_DOUBLE);
    write_uint64(bit_cast<uint64>(Double::cast(object)->value()));
    return true;
  } else if (is_string(object)) {
    return encode_copy(object, TAG_STRING);
  } else if (is_array(object)) {
    Array* array = Array::cast(object);
    return encode_array(array, array->length());
  } else if (is_large_integer(object)) {
    write_uint8(TAG_LARGE_INTEGER);
    write_uint64(bit_cast<uint64>(LargeInteger::cast(object)->value()));
    return true;
  } else if (is_heap_object(object)) {
    printf("[message encoder: cannot encode object with class tag = %d]\n", HeapObject::cast(object)->class_tag());
  }
  return false;
}

bool MessageEncoder::encode_array(Array* object, int size) {
  write_uint8(TAG_ARRAY);
  write_cardinal(size);
  for (int i = 0; i < size; i++) {
    if (!encode(object->at(i))) return false;
  }
  return true;
}

bool MessageEncoder::encode_map(Instance* instance) {
  write_uint8(TAG_MAP);

  Object* object = instance->at(Instance::MAP_BACKING_INDEX);
  if (is_smi(object)) return false;
  HeapObject* backing = HeapObject::cast(object);

  object = instance->at(Instance::MAP_SIZE_INDEX);
  if (!is_smi(object)) return false;
  word size = Smi::cast(object)->value();

  write_cardinal(size);
  if (size == 0) return true;  // Do this before looking at the backing, which may be null.
  Smi* class_id = backing->class_id();
  if (class_id == _program->list_class_id()) {
    object = Instance::cast(backing)->at(Instance::LIST_ARRAY_INDEX);
    if (is_smi(object)) return false;
    backing = HeapObject::cast(object);
  }
  class_id = backing->class_id();
  if (class_id != _program->array_class_id()) {
    if (class_id == _program->large_array_class_id()) {
      printf("[message encoder: cannot encode large map]\n");
    }
    return false;
  }
  Array* array = Array::cast(backing);
  int count = 0;
  for (int i = 0; count < size; i += 2) {
    Object* key = array->at(i);
    Object* value = array->at(i + 1);
    if (is_smi(key) || HeapObject::cast(key)->class_id() != _program->tombstone_class_id()) {
      if (!encode(key)) return false;
      if (!encode(value)) return false;
      count++;
    }
  }
  return true;
}

bool MessageEncoder::encode_byte_array(ByteArray* object) {
  if (_flatten || !object->has_external_address()) {
    return encode_copy(object, TAG_BYTE_ARRAY);
  }

  ASSERT(!_flatten);
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

#ifndef TOIT_FREERTOS
bool MessageEncoder::encode_arguments(char** argv, int argc) {
  write_uint8(TAG_ARRAY);
  write_cardinal(argc);
  for (int i = 0; i < argc; i++) {
    int length = strlen(argv[i]);
    write_uint8(TAG_STRING_INLINE);
    write_cardinal(length);
    if (!encoding_for_size()) {
      memcpy(&_buffer[_cursor], argv[i], length);
    }
    _cursor += length;
  }
  return true;
}

bool MessageEncoder::encode_bundles(SnapshotBundle system, SnapshotBundle application) {
  write_uint8(TAG_ARRAY);
  write_cardinal(2);
  return encode_byte_array_external(system.buffer(), system.size()) &&
      encode_byte_array_external(application.buffer(), application.size());
}
#endif

bool MessageEncoder::encode_byte_array_external(void* data, int length) {
  if (_flatten) return false;
  write_uint8(TAG_BYTE_ARRAY);
  write_cardinal(length);
  write_pointer(data);
  if (!encoding_for_size()) {
    if (_copied_count >= ARRAY_SIZE(_copied)) {
      // TODO(kasper): Report meaningful error.
      return false;
    }
    _copied[_copied_count++] = data;
  }
  return true;
}

bool MessageEncoder::encode_copy(Object* object, int tag) {
  ASSERT(tag == TAG_STRING || tag == TAG_BYTE_ARRAY);
  ASSERT(TAG_STRING_INLINE == TAG_STRING + 1);
  ASSERT(TAG_BYTE_ARRAY_INLINE == TAG_BYTE_ARRAY + 1);

  const uint8* source;
  int length = 0;
  if (!object->byte_content(_program, &source, &length, STRINGS_OR_BYTE_ARRAYS)) {
    // TODO(kasper): Report meaningful error.
    return false;
  }

  // To avoid too many small allocations, we inline the content of the small strings or byte arrays.
  if (_flatten || length <= MESSAGING_ENCODING_MAX_INLINED_SIZE) {
    write_uint8(tag + 1);
    write_cardinal(length);
    if (!encoding_for_size()) {
      memcpy(&_buffer[_cursor], source, length);
    }
    _cursor += length;
    return true;
  }

  ASSERT(!_flatten);
  void* data = null;
  if (!encoding_for_size()) {
    // Strings are '\0'-terminated, so we need to make sure the allocated
    // memory is big enough for that and remember to copy it over.
    int extra = (tag == TAG_STRING) ? 1 : 0;
    int heap_tag = (tag == TAG_STRING) ? EXTERNAL_STRING_MALLOC_TAG : EXTERNAL_BYTE_ARRAY_MALLOC_TAG;
    HeapTagScope scope(ITERATE_CUSTOM_TAGS + heap_tag);
    data = malloc(length + extra);
    if (data == null) {
      _malloc_failed = true;
      return false;
    }
    if (_copied_count >= ARRAY_SIZE(_copied)) {
      // TODO(kasper): Report meaningful error.
      return false;
    }
    _copied[_copied_count++] = data;
    memcpy(data, source, length + extra);
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

MessageDecoder::MessageDecoder(Process* process, const uint8* buffer)
    : _process(process)
    , _program(process ? process->program() : null)
    , _buffer(buffer) {
}

bool MessageDecoder::decode_process_message(const uint8* buffer, int* value) {
  MessageDecoder decoder(null, buffer);
  // TODO(kasper): Make this more robust. We don't know the content.
  Object* object = decoder.decode();
  if (is_smi(object)) {
    *value = Smi::cast(object)->value();
    return true;
  }
  return false;
}

void MessageDecoder::register_external_allocations() {
  ObjectHeap* heap = _process->object_heap();
  for (unsigned i = 0; i < _externals_count; i++) {
    heap->register_external_allocation(_externals_sizes[i]);
  }
}

void MessageDecoder::remove_disposing_finalizers() {
  ObjectHeap* heap = _process->object_heap();
  for (unsigned i = 0; i < _externals_count; i++) {
    heap->remove_vm_finalizer(_externals[i]);
  }
}

void MessageDecoder::register_external(HeapObject* object, int length) {
  unsigned index = _externals_count;
  if (index >= ARRAY_SIZE(_externals)) {
    FATAL("[message decoder: too many externals: %d]", index + 1);
  }
  _externals[index] = object;
  _externals_sizes[index] = length;
  _externals_count++;
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
      return decode_string(false);
    case TAG_STRING_INLINE:
      return decode_string(true);
    case TAG_ARRAY:
      return decode_array();
    case TAG_MAP:
      return decode_map();
    case TAG_BYTE_ARRAY:
      return decode_byte_array(false);
    case TAG_BYTE_ARRAY_INLINE:
      return decode_byte_array(true);
    case TAG_DOUBLE:
      return decode_double();
    case TAG_LARGE_INTEGER:
      return decode_large_integer();
    default:
      FATAL("[message decoder: unhandled message tag: %d]", tag);
  }
  return null;
}

void MessageDecoder::deallocate(uint8* buffer) {
  if (buffer == null) return;
  MessageDecoder decoder(buffer);
  decoder.deallocate();
  free(buffer);
}

void MessageDecoder::deallocate() {
  int tag = read_uint8();
  switch (tag) {
    case TAG_POSITIVE_SMI:
    case TAG_NEGATIVE_SMI:
      read_cardinal();
      break;
    case TAG_NULL:
    case TAG_TRUE:
    case TAG_FALSE:
      break;
    case TAG_STRING:
    case TAG_BYTE_ARRAY:
      read_cardinal();
      free(read_pointer());
      break;
    case TAG_STRING_INLINE:
    case TAG_BYTE_ARRAY_INLINE: {
      int length = read_cardinal();
      _cursor += length;
      break;
    }
    case TAG_ARRAY: {
      int length = read_cardinal();
      for (int i = 0; i < length; i++) deallocate();
      break;
    }
    case TAG_DOUBLE:
    case TAG_LARGE_INTEGER:
      read_uint64();
      break;
    default:
      FATAL("[message decoder: unhandled message tag: %d]", tag);
  }
}

Object* MessageDecoder::decode_string(bool inlined) {
  int length = read_cardinal();
  String* result = null;
  if (inlined) {
    ASSERT(length <= String::max_internal_size_in_process());
    // We ignore the specific error because we are below the maximum internal string
    // size, so we know it's an internal allocation error.
    Error* error = null;
    result = _process->allocate_string(reinterpret_cast<const char*>(&_buffer[_cursor]), length, &error);
    ASSERT(result == null || result->content_on_heap());
    _cursor += length;
  } else {
    uint8* data = read_pointer();
    result = _process->object_heap()->allocate_external_string(length, data, true);
    if (result != null) register_external(result, length + 1);  // Account for '\0'-termination.
  }
  if (result == null) {
    _allocation_failed = true;
  }
  return result;
}

Object* MessageDecoder::decode_array() {
  int length = read_cardinal();
  Array* result = _process->object_heap()->allocate_array(length, Smi::zero());
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

Object* MessageDecoder::decode_map() {
  int size = read_cardinal();
  Instance* result = _process->object_heap()->allocate_instance(_program->map_class_id());
  if (result == null) {
    _allocation_failed = true;
    return null;
  }
  if (size == 0) {
    result->at_put(Instance::MAP_SIZE_INDEX, Smi::from(0));
    result->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(0));
    result->at_put(Instance::MAP_INDEX_INDEX, _program->null_object());
    result->at_put(Instance::MAP_BACKING_INDEX, _program->null_object());
    return result;
  }
  Array* array = _process->object_heap()->allocate_array(size * 2, Smi::zero());
  if (array == null) {
    _allocation_failed = true;
    return null;
  }
  for (int i = 0; i < size * 2; i++) {
    Object* inner = decode();
    if (_allocation_failed) return null;
    array->at_put(i, inner);
  }
  result->at_put(Instance::MAP_SIZE_INDEX, Smi::from(size));
  result->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(0));
  result->at_put(Instance::MAP_INDEX_INDEX, _program->null_object());
  result->at_put(Instance::MAP_BACKING_INDEX, array);
  return result;
}

Object* MessageDecoder::decode_byte_array(bool inlined) {
  int length = read_cardinal();
  ByteArray* result = null;
  if (inlined) {
    ASSERT(length <= ByteArray::max_internal_size_in_process());
    Error* error = null;
    result = _process->allocate_byte_array(length, &error, false);
    if (result != null) {
      ASSERT(!result->has_external_address());
      ByteArray::Bytes bytes(result);
      memcpy(bytes.address(), &_buffer[_cursor], length);
    }
    _cursor += length;
  } else {
    uint8* data = read_pointer();
    result = _process->object_heap()->allocate_external_byte_array(length, data, true, false);
    if (result != null) register_external(result, length);
  }
  if (result == null) {
    _allocation_failed = true;
  }
  return result;
}

bool MessageDecoder::decode_byte_array_external(void** data, int* length) {
  int tag = read_uint8();
  if (tag == TAG_BYTE_ARRAY) {
    *length = read_cardinal();
    *data = read_pointer();
    return true;
  } else if (tag == TAG_BYTE_ARRAY_INLINE) {
    int encoded_length = *length = read_cardinal();
    void* copy = malloc(encoded_length);
    if (copy == null) {
      _allocation_failed = true;
      return false;
    }
    memcpy(copy, &_buffer[_cursor], encoded_length);
    *data = copy;
    return true;
  }
  return false;
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
  memcpy(&result, &_buffer[_cursor], sizeof(result));
  _cursor += sizeof(result);
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
  memcpy(&result, &_buffer[_cursor], sizeof(result));
  _cursor += sizeof(result);
  return result;
}

bool ExternalSystemMessageHandler::start() {
  ASSERT(_process == null);
  Process* process = _vm->scheduler()->run_external(this);
  if (process == null) return false;
  _process = process;
  return true;
}

int ExternalSystemMessageHandler::pid() const {
  return _process ? _process->id() : -1;
}

bool ExternalSystemMessageHandler::send(int pid, int type, void* data, int length, bool discard) {
  int buffer_size = 0;
  { MessageEncoder encoder(null);
    encoder.encode_byte_array_external(data, length);
    buffer_size = encoder.size();
  }

  uint8* buffer = unvoid_cast<uint8*>(malloc(buffer_size));
  if (buffer == null) {
    if (discard) free(data);
    return false;
  }
  MessageEncoder encoder(buffer);
  encoder.encode_byte_array_external(data, length);

  SystemMessage* message = _new SystemMessage(type, _process->group()->id(), _process->id(), buffer);
  if (message == null) {
    if (discard) encoder.free_copied();
    free(buffer);
    return false;
  }
  scheduler_err_t result = _vm->scheduler()->send_message(pid, message);
  if (result == MESSAGE_OK) return true;
  message->free_data_but_keep_externals();
  if (discard) encoder.free_copied();
  delete message;
  return false;
}

Interpreter::Result ExternalSystemMessageHandler::run() {
  Process* process = _process;
  while (true) {
    Message* message = process->peek_message();
    if (message == null) {
      return Interpreter::Result(Interpreter::Result::YIELDED);
    }
    if (message->is_system()) {
      SystemMessage* system = static_cast<SystemMessage*>(message);
      MessageDecoder decoder(system->data());
      void* data = null;
      int length = 0;
      bool success = decoder.decode_byte_array_external(&data, &length);

      // If the allocation failed, we ask the handler if we should retry the failed
      // allocation. If so, we leave the message in place and try again. Otherwise,
      // we remove it but do not call on_message.
      bool allocation_failed = !success && decoder.allocation_failed();
      if (allocation_failed && on_failed_allocation(length)) continue;

      int pid = system->pid();
      int type = system->type();
      if (success) {
        system->free_data_but_keep_externals();
      }
      process->remove_first_message();
      if (success) {
        on_message(pid, type, data, length);
      }
    }
  }
}

void ExternalSystemMessageHandler::collect_garbage(bool try_hard) {
  if (_process) {
    _vm->scheduler()->gc(_process, true, try_hard);
  }
}

}  // namespace toit
