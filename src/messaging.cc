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

MessageEncoder::MessageEncoder(Process* process, uint8* buffer)
    : _process(process)
    , _program(process ? process->program() : null)
    , _buffer(buffer) {
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
  } else if (object->is_byte_array()) {
    return encode_byte_array(ByteArray::cast(object));
  } else if (object->is_double()) {
    write_uint8(TAG_DOUBLE);
    write_uint64(bit_cast<uint64>(Double::cast(object)->value()));
    return true;
  } else if (object->is_string()) {
    return encode_copy(object, TAG_STRING);
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

bool MessageEncoder::encode_byte_array_external(void* data, int length) {
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
  if (length <= MESSAGING_ENCODING_MAX_INLINED_SIZE) {
    write_uint8(tag + 1);
    write_cardinal(length);
    if (!encoding_for_size()) {
      memcpy(&_buffer[_cursor], source, length);
    }
    _cursor += length;
    return true;
  }

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

MessageDecoder::MessageDecoder(Process* process, uint8* buffer)
    : _process(process)
    , _program(process ? process->program() : null)
    , _buffer(buffer) {
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

Object* MessageDecoder::decode_string(bool inlined) {
  int length = read_cardinal();
  String* result = null;
  if (inlined) {
    ASSERT(length <= String::max_internal_size_in_process());
    // We ignore the specific error because we are below the maximum internal string
    // size, so we know it's an internal allocation error.
    Error* error = null;
    result = _process->allocate_string(reinterpret_cast<char*>(&_buffer[_cursor]), length, &error);
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

bool ExternalSystemMessageHandler::send(int pid, int type, void* data, int length) {
  int buffer_size = 0;
  { MessageEncoder encoder(null);
    encoder.encode_byte_array_external(data, length);
    buffer_size = encoder.size();
  }

  uint8* buffer = unvoid_cast<uint8*>(malloc(buffer_size));
  if (buffer == null) {
    free(data);
    return false;
  }
  MessageEncoder encoder(buffer);
  encoder.encode_byte_array_external(data, length);

  SystemMessage* message = _new SystemMessage(type, _process->group()->id(), _process->id(),
      buffer, buffer_size);
  if (message == null) {
    encoder.free_copied();
    free(buffer);
    return false;
  }
  scheduler_err_t result = _vm->scheduler()->send_message(pid, message);
  if (result == MESSAGE_OK) return true;
  encoder.free_copied();
  delete message;
  return false;
}

Interpreter::Result ExternalSystemMessageHandler::run() {
  while (true) {
    Message* message = _process->peek_message();
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
      _process->remove_first_message();
      if (success) {
        on_message(pid, type, data, length);
      }
    }
  }
}

void ExternalSystemMessageHandler::collect_garbage(bool try_hard) {
  if (_process) {
    _vm->scheduler()->scavenge(_process, true, try_hard);
  }
}

}  // namespace toit
