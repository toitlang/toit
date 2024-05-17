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
#include <toit/toit.h>

#include "objects.h"
#include "process.h"
#include "scheduler.h"
#include "vm.h"

#include "objects_inline.h"

namespace toit {

enum MessageTag {
  TAG_OVERFLOWN = 0,
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

static int TISON_VERSION = 1;

// The first 4 bytes of a TISON message is a marker that starts with
// a non-ASCII character. This makes it trivial to distinguish a TISON
// message from a similar message encoded to JSON or UBJSON.
static const uint32 TISON_MARKER        = 0xa68900f7;
static const uint32 TISON_VERSION_MASK  = 0x0000ff00;
static const uint32 TISON_VERSION_SHIFT = 8;

class NestingTracker {
 public:
  NestingTracker(int* nesting) : nesting_(nesting) {
    (*nesting)++;
  }

  ~NestingTracker() {
    (*nesting_)--;
  }

 private:
  int* nesting_;
};

SystemMessage::SystemMessage(int type, int gid, int pid, MessageEncoder* encoder)
    : type_(type)
    , gid_(gid)
    , pid_(pid)
    , data_(encoder->take_buffer()) {}

SystemMessage::SystemMessage(int type, int gid, int pid, uint8* data)
    : type_(type)
    , gid_(gid)
    , pid_(pid)
    , data_(data) {}

void SystemMessage::free_data_and_externals() {
  MessageDecoder::deallocate(data_);
  data_ = null;
}

MessageEncoder::MessageEncoder(Process* process, uint8* buffer, MessageFormat format, bool take_ownership_of_buffer)
    : process_(process)
    , program_(process ? process->program() : null)
    , format_(format)
    , buffer_(buffer)
    , take_ownership_of_buffer_(take_ownership_of_buffer) {}

void MessageEncoder::encode_process_message(uint8* buffer, uint8 value) {
  MessageEncoder encoder(null, buffer);
  encoder.encode(Smi::from(value));
  encoder.take_buffer();  // Don't free the buffer in the destructor.
  ASSERT(encoder.size() <= MESSAGING_PROCESS_MESSAGE_SIZE);
}

MessageEncoder::~MessageEncoder() {
  for (unsigned i = 0; i < copied_count_; i++) {
    free(copied_[i]);
  }
  if (take_ownership_of_buffer_) free(buffer_);
}

uint8* MessageEncoder::take_buffer() {
  for (unsigned i = 0; i < externals_count_; i++) {
    ByteArray* array = externals_[i];
    // Neuter the byte array. The contents of the array is now linked to from
    // an enqueued SystemMessage and will be used to construct a new external
    // byte array in the receiving process.
    array->neuter(process_);

    // Optimization: Eagerly remove any disposing finalizer, so the garbage
    // collector does not have to deal with disposing a neutered byte array.
    array->clear_has_active_finalizer();
  }
  for (unsigned i = 0; i < copied_count_; i++) {
    copied_[i] = null;
  }

  uint8* result = buffer_;
  buffer_ = null;
  return result;
}

bool TisonEncoder::encode(Object* object) {
  ASSERT(encoding_tison());
  uint32 marker = TISON_MARKER | (TISON_VERSION << TISON_VERSION_SHIFT);
  write_uint32(marker);
  if (!encoding_for_size()) {
    ASSERT(payload_size() > 0);
    write_cardinal(payload_size());
  }
  bool result = encode_any(object);
  if (!result) return false;
  // Compute the number of bytes we need to encode the payload size.
  // Later, when we're not encoding for size, we know the payload size
  // and will encode this before the payload.
  if (encoding_for_size()) {
    uword payload_size = size() - sizeof(uint32);
    ASSERT(payload_size > 0 && payload_size_ == 0);
    // Make the payload size available to the outside.
    payload_size_ = payload_size;
    // Encode the payload size, so the full size is correct.
    write_cardinal(payload_size);
  }
  return true;
}

bool MessageEncoder::encode_any(Object* object) {
  NestingTracker tracking(&nesting_);
  if (nesting_ > MESSAGING_ENCODING_MAX_NESTING) {
    nesting_too_deep_ = true;
    return false;
  }

  if (is_smi(object)) {
    word value = Smi::value(object);
    if (value >= 0) {
      write_uint8(TAG_POSITIVE_SMI);
      write_cardinal(value);
    } else {
      write_uint8(TAG_NEGATIVE_SMI);
      write_cardinal(-value);
    }
    return true;
  }

  Program* program = program_;
  if (is_instance(object)) {
    Instance* instance = Instance::cast(object);
    Smi* class_id = instance->class_id();
    if (class_id == program->list_class_id()) {
      Object* size = instance->at(Instance::LIST_SIZE_INDEX);
      if (!is_smi(size)) return false;
      return encode_list(instance, 0, Smi::value(size));
    } else if (class_id == program->list_slice_class_id()) {
      Object* from_object = instance->at(Instance::LIST_SLICE_FROM_INDEX);
      Object* to_object = instance->at(Instance::LIST_SLICE_TO_INDEX);
      if (!is_smi(from_object) || !is_smi(to_object)) return false;
      word from = Smi::value(from_object);
      word to = Smi::value(to_object);
      Object* backing_object = instance->at(Instance::LIST_SLICE_LIST_INDEX);
      if (is_array(backing_object)) {
        Array* backing = Array::cast(backing_object);
        return encode_array(backing, from, to);
      } else if (is_instance(backing_object)) {
        Instance* backing = Instance::cast(backing_object);
        Smi* backing_class_id = backing->class_id();
        if (backing_class_id != program->list_class_id()) {
          problematic_class_id_ = Smi::value(backing_class_id);
          return false;
        }
        return encode_list(backing, from, to);
      } else {
        return false;
      }
    } else if (class_id == program->map_class_id()) {
      return encode_map(instance);
    } else if (class_id == program->byte_array_cow_class_id()) {
      return encode_copy(object, TAG_BYTE_ARRAY);
    } else if (class_id == program->byte_array_slice_class_id()) {
      return encode_copy(object, TAG_BYTE_ARRAY);
    } else if (class_id == program->string_byte_slice_class_id()) {
      return encode_copy(object, TAG_BYTE_ARRAY);
    } else if (class_id == program->string_slice_class_id()) {
      return encode_copy(object, TAG_STRING);
    } else {
      problematic_class_id_ = Smi::value(class_id);
    }
  } else if (object == program->null_object()) {
    write_uint8(TAG_NULL);
    return true;
  } else if (object == program->true_object()) {
    write_uint8(TAG_TRUE);
    return true;
  } else if (object == program->false_object()) {
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
    return encode_array(array, 0, array->length());
  } else if (is_large_integer(object)) {
    write_uint8(TAG_LARGE_INTEGER);
    write_uint64(bit_cast<uint64>(LargeInteger::cast(object)->value()));
    return true;
  } else if (is_heap_object(object)) {
    printf("[message encoder: cannot encode object with class tag = %d]\n", HeapObject::cast(object)->class_tag());
  }
  return false;
}

bool MessageEncoder::encode_array(Array* object, word from, word to) {
  ASSERT(from <= to);
  write_uint8(TAG_ARRAY);
  write_cardinal(to - from);
  for (word i = from; i < to; i++) {
    if (!encode_any(object->at(i))) return false;
  }
  return true;
}

bool MessageEncoder::encode_list(Instance* instance, word from, word to) {
  Object* backing = instance->at(Instance::LIST_ARRAY_INDEX);
  if (is_smi(backing)) return false;
  Smi* class_id = HeapObject::cast(backing)->class_id();
  if (class_id == program_->array_class_id()) {
    Array* array = Array::cast(backing);
    return encode_array(array, from, to);
  } else if (class_id == program_->large_array_class_id()) {
    printf("[message encoder: cannot encode large array]\n");
  }
  return false;
}

bool MessageEncoder::encode_map(Instance* instance) {
  write_uint8(TAG_MAP);

  Object* object = instance->at(Instance::MAP_BACKING_INDEX);
  if (is_smi(object)) return false;
  HeapObject* backing = HeapObject::cast(object);

  object = instance->at(Instance::MAP_SIZE_INDEX);
  if (!is_smi(object)) return false;
  word size = Smi::value(object);

  write_cardinal(size);
  if (size == 0) return true;  // Do this before looking at the backing, which may be null.
  Smi* class_id = backing->class_id();
  if (class_id == program_->list_class_id()) {
    object = Instance::cast(backing)->at(Instance::LIST_ARRAY_INDEX);
    if (is_smi(object)) return false;
    backing = HeapObject::cast(object);
  }
  class_id = backing->class_id();
  if (class_id != program_->array_class_id()) {
    if (class_id == program_->large_array_class_id()) {
      printf("[message encoder: cannot encode large map]\n");
    }
    return false;
  }
  Array* array = Array::cast(backing);
  word count = 0;
  for (word i = 0; count < size; i += 2) {
    Object* key = array->at(i);
    Object* value = array->at(i + 1);
    if (is_smi(key) || HeapObject::cast(key)->class_id() != program_->tombstone_class_id()) {
      if (!encode_any(key)) return false;
      if (!encode_any(value)) return false;
      count++;
    }
  }
  return true;
}

bool MessageEncoder::encode_byte_array(ByteArray* object) {
  if (encoding_tison() || !object->has_external_address()) {
    return encode_copy(object, TAG_BYTE_ARRAY);
  }

  ASSERT(!encoding_tison());
  ByteArray::Bytes bytes(object);
  write_uint8(TAG_BYTE_ARRAY);
  write_cardinal(bytes.length());
  write_pointer(bytes.address());
  if (externals_count_ >= MESSAGING_ENCODING_MAX_EXTERNALS) {
    too_many_externals_ = true;
    return false;
  }
  externals_[externals_count_++] = object;
  return true;
}

#ifndef TOIT_FREERTOS
bool MessageEncoder::encode_arguments(char** argv, int argc) {
  write_uint8(TAG_ARRAY);
  write_cardinal(argc);
  for (int i = 0; i < argc; i++) {
    word length = strlen(argv[i]);
    write_uint8(TAG_STRING_INLINE);
    write_cardinal(length);
    if (!encoding_for_size()) {
      memcpy(&buffer_[cursor_], argv[i], length);
    }
    cursor_ += length;
  }
  return true;
}

bool MessageEncoder::encode_bundles(SnapshotBundle system, SnapshotBundle application) {
  write_uint8(TAG_ARRAY);
  write_cardinal(2);
  return encode_bytes_external(system.buffer(), system.size()) &&
      encode_bytes_external(application.buffer(), application.size());
}
#endif

bool MessageEncoder::encode_bytes_external(void* data, word length, bool free_on_failure) {
  if (encoding_tison()) return false;
  write_uint8(TAG_BYTE_ARRAY);
  write_cardinal(length);
  write_pointer(data);
  if (!encoding_for_size() && free_on_failure) {
    if (copied_count() >= ARRAY_SIZE(copied_)) {
      // TODO(kasper): Report meaningful error.
      return false;
    }
    copied_[copied_count_++] = data;
  }
  return true;
}

bool MessageEncoder::encode_rpc_reply_external(int id,
                                               bool is_exception, const char* exception,
                                               void* data, word length, bool free_on_failure) {
  if (encoding_tison()) return false;

  // Either:
  // - it's an exception: [id, true, exception-string, null], or
  // - it's not an exception: [id, false, data].
  write_uint8(TAG_ARRAY);
  write_cardinal(is_exception ? 4 : 3);  // Length.
  // Slot 0:
  write_uint8(TAG_POSITIVE_SMI);
  write_cardinal(id);

  if (is_exception) {
    // Slot 1:
    write_uint8(TAG_TRUE);

    // Slot 2:
    // Inline the exception message.
    int exception_length = strnlen(exception, MESSAGING_ENCODING_MAX_INLINED_SIZE + 1);
    if (exception_length > MESSAGING_ENCODING_MAX_INLINED_SIZE) return false;
    write_uint8(TAG_STRING_INLINE);
    write_cardinal(exception_length);
    if (!encoding_for_size()) {
      memcpy(&buffer_[cursor_], exception, exception_length);
    }
    cursor_ += exception_length;

    // Slot 3:
    // No stack information.
    write_uint8(TAG_NULL);
    return true;
  } else {
    // Slot 2:
    write_uint8(TAG_FALSE);  // Not an exception.

    // Slot 3:
    return encode_bytes_external(data, length, free_on_failure);
  }
}

bool MessageEncoder::encode_copy(Object* object, int tag) {
  ASSERT(tag == TAG_STRING || tag == TAG_BYTE_ARRAY);
  ASSERT(TAG_STRING_INLINE == TAG_STRING + 1);
  ASSERT(TAG_BYTE_ARRAY_INLINE == TAG_BYTE_ARRAY + 1);

  const uint8* source;
  word length = 0;
  if (!object->byte_content(program_, &source, &length, STRINGS_OR_BYTE_ARRAYS)) {
    // TODO(kasper): Report meaningful error.
    return false;
  }

  // To avoid too many small allocations, we inline the content of the small strings or byte arrays.
  if (encoding_tison() || length <= MESSAGING_ENCODING_MAX_INLINED_SIZE) {
    write_uint8(tag + 1);
    write_cardinal(length);
    if (!encoding_for_size()) {
      memcpy(&buffer_[cursor_], source, length);
    }
    cursor_ += length;
    return true;
  }

  ASSERT(!encoding_tison());
  void* data = null;
  if (!encoding_for_size()) {
    // Strings are '\0'-terminated, so we need to make sure the allocated
    // memory is big enough for that and remember to copy it over.
    int extra = (tag == TAG_STRING) ? 1 : 0;
    int heap_tag = (tag == TAG_STRING) ? EXTERNAL_STRING_MALLOC_TAG : EXTERNAL_BYTE_ARRAY_MALLOC_TAG;
    HeapTagScope scope(ITERATE_CUSTOM_TAGS + heap_tag);
    data = malloc(length + extra);
    if (data == null) {
      malloc_failed_ = true;
      return false;
    }
    if (copied_count_ >= ARRAY_SIZE(copied_)) {
      // TODO(kasper): Report meaningful error.
      return false;
    }
    copied_[copied_count_++] = data;
    memcpy(data, source, length + extra);
  }
  write_uint8(tag);
  write_cardinal(length);
  write_pointer(data);
  return true;
}

void MessageEncoder::write_pointer(void* value) {
  if (!encoding_for_size()) memcpy(&buffer_[cursor_], &value, WORD_SIZE);
  cursor_ += WORD_SIZE;
}

void MessageEncoder::write_cardinal(uword value) {
  while (value >= 128) {
    write_uint8((uint8) (value % 128 + 128));
    value >>= 7;
  }
  write_uint8((uint8) value);
}

void MessageEncoder::write_uint32(uint32 value) {
  if (!encoding_for_size()) memcpy(&buffer_[cursor_], &value, sizeof(uint32));
  cursor_ += sizeof(uint32);
}

void MessageEncoder::write_uint64(uint64 value) {
  if (!encoding_for_size()) memcpy(&buffer_[cursor_], &value, sizeof(uint64));
  cursor_ += sizeof(uint64);
}

MessageDecoder::MessageDecoder(Process* process,
                               const uint8* buffer,
                               word size,
                               MessageFormat format)
    : process_(process)
    , program_(process ? process->program() : null)
    , buffer_(buffer)
    , size_(size)
    , format_(format) {}

bool MessageDecoder::decode_process_message(const uint8* buffer, int* value) {
  MessageDecoder decoder(null, buffer);
  // TODO(kasper): Make this more robust. We don't know the content.
  Object* object = decoder.decode();
  if (is_smi(object)) {
    *value = Smi::value(object);
    return true;
  }
  return false;
}

void MessageDecoder::register_external_allocations() {
  ASSERT(!decoding_tison());
  ObjectHeap* heap = process_->object_heap();
  for (unsigned i = 0; i < externals_count(); i++) {
    heap->register_external_allocation(externals_sizes_[i]);
  }
}

void MessageDecoder::remove_disposing_finalizers() {
  ASSERT(!decoding_tison());
  for (unsigned i = 0; i < externals_count(); i++) {
    externals_[i]->clear_has_active_finalizer();
  }
}

void MessageDecoder::register_external(HeapObject* object, word length) {
  ASSERT(!decoding_tison());
  unsigned index = externals_count();
  if (index >= ARRAY_SIZE(externals_)) {
    FATAL("[message decoder: too many externals: %d]", index + 1);
  }
  externals_[index] = object;
  externals_sizes_[index] = length;
  externals_count_++;
}

Object* TisonDecoder::decode() {
  ASSERT(decoding_tison());
  uint32 expected = TISON_MARKER | (TISON_VERSION << TISON_VERSION_SHIFT);
  uint32 marker = read_uint32();
  if (marker != expected) {
    if ((marker & ~TISON_VERSION_MASK) == (expected & ~TISON_VERSION_MASK)) {
      int version = (marker & TISON_VERSION_MASK) >> TISON_VERSION_SHIFT;
      printf("[message decoder: wrong tison version %d - expected %d]\n",
          version, TISON_VERSION);
    } else {
      printf("[message decoder: wrong tison marker 0x%" PRIx32 " - expected 0x%" PRIx32 "]\n",
          marker, expected);
    }
    return mark_malformed();
  }
  word payload_size = read_cardinal();
  if (payload_size != remaining()) return mark_malformed();
  Object* result = decode_any();
  if (!success()) return result;
  if (remaining() != 0) return mark_malformed();
  return result;
}

Object* MessageDecoder::decode_any() {
  int tag = read_uint8();
  switch (tag) {
    case TAG_OVERFLOWN:
      return mark_malformed();
    case TAG_POSITIVE_SMI:
      return Smi::from(read_cardinal());
    case TAG_NEGATIVE_SMI:
      return Smi::from(-static_cast<word>(read_cardinal()));
    case TAG_NULL:
      return program_->null_object();
    case TAG_TRUE:
      return program_->true_object();
    case TAG_FALSE:
      return program_->false_object();
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
      printf("[message decoder: unhandled message tag: %d]\n", tag);
      return mark_malformed();
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
      word length = read_cardinal();
      cursor_ += length;
      break;
    }
    case TAG_ARRAY:
    case TAG_MAP: {
      word length = read_cardinal();
      // Maps have two nested encodings per entry.
      if (tag == TAG_MAP) length *= 2;
      for (word i = 0; i < length; i++) deallocate();
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
  word length = read_cardinal();
  if (length == 0 && overflown()) return mark_malformed();
  String* result = null;
  if (inlined) {
    result = process_->allocate_string(reinterpret_cast<const char*>(&buffer_[cursor_]), length);
    cursor_ += length;
  } else if (decoding_tison()) {
    return mark_malformed();
  } else {
    uint8* data = read_pointer();
    result = process_->object_heap()->allocate_external_string(length, data, true);
    if (result) register_external(result, length + 1);  // Account for '\0'-termination.
  }
  if (result == null) return mark_allocation_failed();
  return result;
}

Object* MessageDecoder::decode_array() {
  word length = read_cardinal();
  if (length == 0 && overflown()) return mark_malformed();
  Array* result = process_->object_heap()->allocate_array(length, Smi::zero());
  if (result == null) return mark_allocation_failed();
  for (word i = 0; i < length; i++) {
    Object* inner = decode_any();
    if (!success()) return inner;
    result->at_put(i, inner);
  }
  return result;
}

Object* MessageDecoder::decode_map() {
  word size = read_cardinal();
  if (size == 0 && overflown()) return mark_malformed();
  Instance* result = process_->object_heap()->allocate_instance(program_->map_class_id());
  if (result == null) return mark_allocation_failed();
  if (size == 0) {
    result->at_put(Instance::MAP_SIZE_INDEX, Smi::from(0));
    result->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(0));
    result->at_put(Instance::MAP_INDEX_INDEX, program_->null_object());
    result->at_put(Instance::MAP_BACKING_INDEX, program_->null_object());
    return result;
  }
  Array* array = process_->object_heap()->allocate_array(size * 2, Smi::zero());
  if (array == null) return mark_allocation_failed();
  for (word i = 0; i < size * 2; i++) {
    Object* inner = decode_any();
    if (!success()) return inner;
    array->at_put(i, inner);
  }
  result->at_put(Instance::MAP_SIZE_INDEX, Smi::from(size));
  result->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(0));
  result->at_put(Instance::MAP_INDEX_INDEX, program_->null_object());
  result->at_put(Instance::MAP_BACKING_INDEX, array);
  return result;
}

Object* MessageDecoder::decode_byte_array(bool inlined) {
  word length = read_cardinal();
  if (length == 0 && overflown()) return mark_malformed();
  ByteArray* result = null;
  if (inlined) {
    result = process_->allocate_byte_array(length, false);
    if (result != null) {
      ByteArray::Bytes bytes(result);
      memcpy(bytes.address(), &buffer_[cursor_], length);
    }
    cursor_ += length;
  } else if (decoding_tison()) {
    return mark_malformed();
  } else {
    uint8* data = read_pointer();
    result = process_->object_heap()->allocate_external_byte_array(length, data, true, false);
    if (result) register_external(result, length);
  }
  if (result == null) return mark_allocation_failed();
  return result;
}

bool MessageDecoder::decode_external_data(void** data, word* length) {
  if (decoding_tison()) return false;
  int tag = read_uint8();
  if (tag == TAG_BYTE_ARRAY) {
    *length = read_cardinal();
    *data = read_pointer();
    return true;
  } else if (tag == TAG_BYTE_ARRAY_INLINE) {
    int encoded_length = *length = read_cardinal();
    // 'malloc' is allowed to return 'null' if the length is zero.
    // We always want to have a valid pointer, so we allocate at least one byte.
    int malloc_length = Utils::max(1, encoded_length);
    void* copy = malloc(malloc_length);
    if (copy == null) {
      mark_allocation_failed();
      return false;
    }
    memcpy(copy, &buffer_[cursor_], encoded_length);
    *data = copy;
    return true;
  } else if (tag == TAG_STRING) {
    *length = read_cardinal();
    *data = read_pointer();
    return true;
  } else if (tag == TAG_STRING_INLINE) {
    int encoded_length = *length = read_cardinal();
    char* copy = unvoid_cast<char*>(malloc(encoded_length + 1));
    if (copy == null) {
      mark_allocation_failed();
      return false;
    }
    memcpy(copy, &buffer_[cursor_], encoded_length);
    copy[encoded_length] = '\0';
    *length = encoded_length;  // Exclude the '\0'.
    *data = copy;
    return true;
  }
  return false;
}

bool MessageDecoder::decode_rpc_request_external(int* id, int* name, void** data, word* length) {
  // An external RPC request is an array consisting of 3 elements,
  // the id, the name and a byte-array.
  if (decoding_tison()) return false;
  int tag = read_uint8();
  if (tag != TAG_ARRAY) return false;
  word array_length = read_cardinal();
  if (array_length != 3) return false;
  tag = read_uint8();
  if (tag != TAG_POSITIVE_SMI) return false;
  *id = read_cardinal();
  if (overflown()) return false;
  tag = read_uint8();
  if (tag != TAG_POSITIVE_SMI) return false;
  *name = read_cardinal();
  if (overflown()) return false;
  return decode_external_data(data, length);
}

Object* MessageDecoder::decode_double() {
  uint64 value = read_uint64();
  if (value == 0 && overflown()) return mark_malformed();
  Double* result = process_->object_heap()->allocate_double(bit_cast<double>(value));
  if (result == null) return mark_allocation_failed();
  return result;
}

Object* MessageDecoder::decode_large_integer() {
  int64 value = read_uint64();
  if (value == 0 && overflown()) return mark_malformed();
  LargeInteger* result = process_->object_heap()->allocate_large_integer(value);
  if (result == null) return mark_allocation_failed();
  return result;
}

uint8* MessageDecoder::read_pointer() {
  uint8* result = null;
  word cursor = cursor_;
  word next = cursor + sizeof(result);
  if (next <= size_) {
    memcpy(&result, &buffer_[cursor], sizeof(result));
  }
  cursor_ = next;
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
  if (byte == 0 && overflown()) return 0;
  result += ((uword) byte) << shift;
  return result;
}

uint32 MessageDecoder::read_uint32() {
  uint32 result = 0;
  word cursor = cursor_;
  word next = cursor + sizeof(result);
  if (next <= size_) {
    memcpy(&result, &buffer_[cursor], sizeof(result));
  }
  cursor_ = next;
  return result;
}

uint64 MessageDecoder::read_uint64() {
  uint64 result = 0;
  word cursor = cursor_;
  word next = cursor + sizeof(result);
  if (next <= size_) {
    memcpy(&result, &buffer_[cursor], sizeof(result));
  }
  cursor_ = next;
  return result;
}

bool ExternalSystemMessageHandler::start(int priority) {
  ASSERT(process_ == null);
  Process* process = vm_->scheduler()->run_external(this);
  if (process == null) return false;
  ASSERT(process_ == process);
  if (priority >= 0) set_priority(Utils::min(priority, 0xff));
  return true;
}

int ExternalSystemMessageHandler::pid() const {
  return process_ ? process_->id() : -1;
}

int ExternalSystemMessageHandler::priority() const {
  int pid = this->pid();
  return (pid < 0) ? -1 : vm_->scheduler()->get_priority(pid);
}

bool ExternalSystemMessageHandler::set_priority(uint8 priority) {
  int pid = this->pid();
  return (pid < 0) ? false : vm_->scheduler()->set_priority(pid, priority);
}

message_err_t ExternalSystemMessageHandler::send_(int pid, int type, void* data, word length, bool free_on_failure) {
  word buffer_size = 0;
  { MessageEncoder encoder(null);
    encoder.encode_bytes_external(data, length);
    buffer_size = encoder.size();
  }

  uint8* buffer = unvoid_cast<uint8*>(malloc(buffer_size));
  if (buffer == null) {
    if (free_on_failure) free(data);
    return MESSAGE_OOM;
  }
  MessageEncoder encoder(buffer);  // Takes over buffer.
  // Takes ownership of the data.
  encoder.encode_bytes_external(data, length, free_on_failure);

  // Takes over the buffer and neuters the message encoder.
  return send_(pid, type, &encoder, free_on_failure);
}

message_err_t ExternalSystemMessageHandler::reply_rpc(int pid,
                                                      int id,
                                                      bool is_exception,
                                                      const char* exception,
                                                      void* data,
                                                      word length,
                                                      bool free_on_failure) {
  word buffer_size = 0;
  { MessageEncoder encoder(null);
    encoder.encode_rpc_reply_external(id, is_exception, exception, data, length, free_on_failure);
    buffer_size = encoder.size();
  }

  uint8* buffer = unvoid_cast<uint8*>(malloc(buffer_size));
  if (buffer == null) {
    if (free_on_failure && !is_exception) free(data);
    return MESSAGE_OOM;
  }
  MessageEncoder encoder(buffer);  // Takes over buffer.
  // Takes ownership of the data.
  encoder.encode_rpc_reply_external(id, is_exception, exception, data, length, free_on_failure);

  int type = SYSTEM_RPC_REPLY;

  // Takes over the buffer and neuters the message encoder.
  return send_(pid, type, &encoder, free_on_failure);
}

message_err_t ExternalSystemMessageHandler::send_(int pid, int type, MessageEncoder* encoder, bool free_on_failure) {
  // Takes over the buffer and neuters the message encoder.
  SystemMessage* system_message = _new SystemMessage(type, process_->group()->id(), process_->id(), encoder);
  if (system_message == null) {
    // No need to free the data or the buffer, since the destructor of the
    // encoder already takes care of that.
    return MESSAGE_OOM;
  }

  // Sending the message can only fail if the pid is invalid.
  message_err_t result = vm_->scheduler()->send_message(pid, system_message, free_on_failure);
  ASSERT(result == MESSAGE_OK || result == MESSAGE_NO_SUCH_RECEIVER);
  if (result != MESSAGE_OK && !free_on_failure) {
    system_message->free_data_but_keep_externals();
    delete system_message;
  }
  return result;
}

Interpreter::Result ExternalSystemMessageHandler::run() {
  Process* process = process_;
  while (true) {
    Message* message = process->peek_message();
    if (message == null) {
      return Interpreter::Result(Interpreter::Result::YIELDED);
    }
    if (message->is_system()) {
      SystemMessage* system_message = static_cast<SystemMessage*>(message);
      int pid = system_message->pid();
      int type = system_message->type();

      int id = -1;  // Handle to respond to.
      int name = -1;  // Id of the method to call.
      void* data = null;
      word length = 0;
      MessageDecoder decoder(system_message->data());
      bool success = false;
      if (type == SYSTEM_RPC_REQUEST && supports_rpc_requests()) {
        success = decoder.decode_rpc_request_external(&id, &name, &data, &length);
      } else {
        success = decoder.decode_external_data(&data, &length);
      }
      if (success && length > INT_MAX) {
        abort();
      }

      // If the allocation failed, we ask the process if we should retry the failed
      // allocation. If so, we leave the message in place and try again. Otherwise,
      // we remove it but do not call on_message.
      bool allocation_failed = !success && decoder.allocation_failed();
      if (allocation_failed && on_failed_allocation(length)) continue;

      if (success) {
        system_message->free_data_but_keep_externals();
      }
      process->remove_first_message();
      if (success) {
        if (type == SYSTEM_RPC_REQUEST && supports_rpc_requests()) {
          on_request(pid, id, name, data, length);
        } else {
          on_message(pid, type, data, length);
        }
      }
    }
  }
}

void ExternalSystemMessageHandler::set_process(Process* process) {
  ASSERT(process_ == null);
  process_ = process;
}

void ExternalSystemMessageHandler::collect_garbage(bool try_hard) {
  if (process_) {
    vm_->scheduler()->gc(process_, true, try_hard);
  }
}

namespace {

struct RegisteredExternalMessageHandler {
  const char* id;
  void* user_context;
  toit_msg_cbs_t callbacks;
};

struct RegisteredExternalMessageHandlerList {
  RegisteredExternalMessageHandlerList* next;
  RegisteredExternalMessageHandler registered_handler;
};

RegisteredExternalMessageHandlerList* registered_message_handlers = null;

class ExternalMessageHandler : public ExternalSystemMessageHandler {
 public:
  ExternalMessageHandler(VM* vm, void* user_context, toit_msg_cbs_t callbacks)
      : ExternalSystemMessageHandler(vm)
      , user_context_(user_context)
      , callbacks_(callbacks) {}

  virtual ~ExternalMessageHandler() {
    if (callbacks_.on_removed != null) callbacks_.on_removed(user_context_);
  }

  void on_created() {
    if (!callbacks_.on_created) return;
    callbacks_.on_created(user_context_, as_msg_context());
  }

  void on_message(int pid, int type, void* data, int length) override {
    if (callbacks_.on_message == null) return;
    if (type != SYSTEM_EXTERNAL_NOTIFICATION) return;
    callbacks_.on_message(user_context_, pid, unvoid_cast<uint8_t*>(data), length);
  }

  message_err_t send_with_err(int pid, int type, void* data, word length, bool free_on_failure) {
    return send_(pid, type, data, length, free_on_failure);
  }

  bool supports_rpc_requests() const override { return true; }

  void on_request(int sender, int id, int name, void* data, int length) override {
    if (callbacks_.on_rpc_request == null) return;
    toit_msg_request_handle_t rpc_handle = {
      .sender = sender,
      .request_handle = id,
      .context = as_msg_context()
    };
    callbacks_.on_rpc_request(user_context_, sender, name, rpc_handle, unvoid_cast<uint8_t*>(data), length);
  }

  toit_msg_context_t* as_msg_context() {
    return reinterpret_cast<toit_msg_context_t*>(this);
  }

  bool on_failed_allocation(word length) override {
    collect_garbage(true);
    return true;
  }

 private:
  void* user_context_;
  toit_msg_cbs_t callbacks_;
};

struct IdHandlerEntry {
  const char* id;
  ExternalMessageHandler* handler;
};

}  // anonymous namespace.

static IdHandlerEntry* id_handler_entry_mapping = null;
static int id_handler_entry_mapping_length = 0;

void create_and_start_external_message_handlers(VM* vm) {
  int count = 0;
  for (RegisteredExternalMessageHandlerList* list = registered_message_handlers; list != null; list = list->next) {
    count++;
  }
  if (count == 0) return;

  // Create the mapping from ID to PID.
  id_handler_entry_mapping = unvoid_cast<IdHandlerEntry*>(malloc(count * sizeof(IdHandlerEntry)));
  id_handler_entry_mapping_length = count;
  if (!id_handler_entry_mapping) {
    FATAL("[OOM while creating external message processs]");
  }

  int i = 0;
  for (RegisteredExternalMessageHandlerList* list = registered_message_handlers; list != null; list = list->next) {
    auto registered_handler = list->registered_handler;
    const char* id = registered_handler.id;
    void* user_context = registered_handler.user_context;
    auto cbs = registered_handler.callbacks;
    ExternalMessageHandler* handler = _new ExternalMessageHandler(vm, user_context, cbs);
    if (!handler) {
      FATAL("[OOM while creating external message processs]");
    }
    if (!handler->start()) {
      FATAL("[failed to start external message process]");
    }
    handler->on_created();
    id_handler_entry_mapping[i].id = id;
    id_handler_entry_mapping[i].handler = handler;
    i++;
  }
  // Free the list.
  while (registered_message_handlers != null) {
    RegisteredExternalMessageHandlerList* next = registered_message_handlers->next;
    free(registered_message_handlers);
    registered_message_handlers = next;
  }
}

int pid_for_external_id(String* id) {
  auto c_id = id->as_cstr();
  for (int i = 0; i < id_handler_entry_mapping_length; i++) {
    auto entry = id_handler_entry_mapping[i];
    if (strcmp(c_id, entry.id) == 0) {
      if (entry.handler == null) return -1;
      return entry.handler->pid();
    }
  }
  return -1;
}

}  // namespace toit

extern "C" {

// Functions that are exported through Toit's C API.

toit_err_t toit_msg_add_handler(const char* id,
                                void* user_context,
                                toit_msg_cbs_t cbs) {
  auto old = toit::registered_message_handlers;
  auto list = toit::unvoid_cast<toit::RegisteredExternalMessageHandlerList*>(
      malloc(sizeof(toit::RegisteredExternalMessageHandlerList)));
  if (list == null) return TOIT_ERR_OOM;
  list->next = old;
  list->registered_handler.id = id;
  list->registered_handler.user_context = user_context;
  list->registered_handler.callbacks = cbs;
  toit::registered_message_handlers = list;
  return TOIT_OK;
}

toit_err_t toit_msg_remove_handler(toit_msg_context_t* context) {
  // TODO(florian): this lookup and removal should be protected by a lock.
  for (int i = 0; i < toit::id_handler_entry_mapping_length; i++) {
    auto entry = toit::id_handler_entry_mapping[i];
    if (toit::void_cast(entry.handler) == toit::void_cast(context)) {
      auto handler = entry.handler;
      toit::id_handler_entry_mapping[i].handler = null;
      delete handler;
      return TOIT_OK;
    }
  }
  return TOIT_ERR_NOT_FOUND;
}

static toit_err_t message_err_to_toit_err(toit::message_err_t err) {
  switch (err) {
    case toit::MESSAGE_OK: return TOIT_OK;
    case toit::MESSAGE_OOM: return TOIT_ERR_OOM;
    case toit::MESSAGE_NO_SUCH_RECEIVER: return TOIT_ERR_NO_SUCH_RECEIVER;
  }
  UNREACHABLE();
}

toit_err_t toit_msg_notify(toit_msg_context_t* context,
                           int target_pid,
                           uint8_t* data, int length,
                           bool free_on_failure) {
  auto handler = reinterpret_cast<toit::ExternalMessageHandler*>(context);
  auto type = toit::SYSTEM_EXTERNAL_NOTIFICATION;
  toit::message_err_t err = handler->send_with_err(target_pid, type, data, length, false);
  if (err == toit::MESSAGE_OOM) {
    toit_gc();
    err = handler->send_with_err(target_pid, type, data, length, false);
  }
  if (free_on_failure && err != toit::MESSAGE_OK) free(data);
  return message_err_to_toit_err(err);
}

toit_err_t toit_msg_request_fail(toit_msg_request_handle_t rpc_handle, const char* error) {
  auto handler = reinterpret_cast<toit::ExternalMessageHandler*>(rpc_handle.context);
  toit::message_err_t err = handler->reply_rpc(rpc_handle.sender, rpc_handle.request_handle, true, error, null, 0, false);
  if (err == toit::MESSAGE_OOM) {
    toit_gc();
    err = handler->reply_rpc(rpc_handle.sender, rpc_handle.request_handle, true, error, null, 0, false);
  }
  return message_err_to_toit_err(err);
}

toit_err_t toit_msg_request_reply(toit_msg_request_handle_t rpc_handle, uint8_t* data, int length, bool free_on_failure) {
  auto handler = reinterpret_cast<toit::ExternalMessageHandler*>(rpc_handle.context);
  toit::message_err_t err = handler->reply_rpc(rpc_handle.sender, rpc_handle.request_handle, false, null, data, length, false);
  if (err == toit::MESSAGE_OOM) {
    toit_gc();
    err = handler->reply_rpc(rpc_handle.sender, rpc_handle.request_handle, false, null, data, length, false);
  }
  if (free_on_failure && err != toit::MESSAGE_OK) free(data);
  return message_err_to_toit_err(err);
}

// TODO(florian): this isn't really a messaging function. It should probably be somewhere else.
toit_err_t toit_gc() {
  toit::VM::current()->scheduler()->gc(NULL, true, true);
  return TOIT_OK;
}

void* toit_malloc(size_t size) {
  void* ptr = malloc(size);
  if (ptr != NULL) return ptr;
  toit_gc();
  return malloc(size);
}

void* toit_calloc(size_t nmemb, size_t size) {
  void* ptr = calloc(nmemb, size);
  if (ptr != NULL) return ptr;
  toit_gc();
  return calloc(nmemb, size);
}

void* toit_realloc(void* ptr, size_t size) {
  void* new_ptr = realloc(ptr, size);
  if (new_ptr != NULL) return new_ptr;
  toit_gc();
  return realloc(ptr, size);
}

} // Extern C.
