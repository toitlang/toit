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

void SystemMessage::free_data_and_externals() {
  MessageDecoder::deallocate(data_);
  data_ = null;
}

MessageEncoder::MessageEncoder(Process* process, uint8* buffer, MessageFormat format)
    : process_(process)
    , program_(process ? process->program() : null)
    , format_(format)
    , buffer_(buffer) {}

void MessageEncoder::encode_process_message(uint8* buffer, uint8 value) {
  MessageEncoder encoder(null, buffer);
  encoder.encode(Smi::from(value));
  ASSERT(encoder.size() <= MESSAGING_PROCESS_MESSAGE_SIZE);
}

void MessageEncoder::free_copied() {
  for (unsigned i = 0; i < copied_count_; i++) {
    free(copied_[i]);
  }
}

void MessageEncoder::neuter_externals() {
  ObjectHeap* heap = process_->object_heap();
  for (unsigned i = 0; i < externals_count_; i++) {
    ByteArray* array = externals_[i];
    // Neuter the byte array. The contents of the array is now linked to from
    // an enqueued SystemMessage and will be used to construct a new external
    // byte array in the receiving process.
    array->neuter(process_);

    // Optimization: Eagerly remove any disposing finalizer, so the garbage
    // collector does not have to deal with disposing a neutered byte array.
    heap->remove_vm_finalizer(array);
  }
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
    unsigned payload_size = size() - sizeof(uint32);
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
    word value = Smi::cast(object)->value();
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
      return encode_list(instance, 0, Smi::cast(size)->value());
    } else if (class_id == program->list_slice_class_id()) {
      Object* list = instance->at(Instance::LIST_SLICE_LIST_INDEX);
      Object* from_object = instance->at(Instance::LIST_SLICE_FROM_INDEX);
      Object* to_object = instance->at(Instance::LIST_SLICE_TO_INDEX);
      if (!is_smi(from_object) || !is_smi(to_object)) return false;
      int from = Smi::cast(from_object)->value();
      int to = Smi::cast(to_object)->value();
      if (is_array(list)) return encode_array(Array::cast(list), from, to);
      return encode_list(Instance::cast(list), from, to);
    } else if (class_id == program->map_class_id()) {
      return encode_map(instance);
    } else if (class_id == program->byte_array_cow_class_id()) {
      return encode_copy(object, TAG_BYTE_ARRAY);
    } else if (class_id == program->byte_array_slice_class_id()) {
      return encode_copy(object, TAG_BYTE_ARRAY);
    } else if (class_id == program->string_slice_class_id()) {
      return encode_copy(object, TAG_STRING);
    } else {
      problematic_class_id_ = class_id->value();
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

bool MessageEncoder::encode_array(Array* object, int from, int to) {
  ASSERT(from <= to);
  write_uint8(TAG_ARRAY);
  write_cardinal(to - from);
  for (int i = from; i < to; i++) {
    if (!encode_any(object->at(i))) return false;
  }
  return true;
}

bool MessageEncoder::encode_list(Instance* instance, int from, int to) {
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
  word size = Smi::cast(object)->value();

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
  int count = 0;
  for (int i = 0; count < size; i += 2) {
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
    int length = strlen(argv[i]);
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
  return encode_byte_array_external(system.buffer(), system.size()) &&
      encode_byte_array_external(application.buffer(), application.size());
}
#endif

bool MessageEncoder::encode_byte_array_external(void* data, int length) {
  if (encoding_tison()) return false;
  write_uint8(TAG_BYTE_ARRAY);
  write_cardinal(length);
  write_pointer(data);
  if (!encoding_for_size()) {
    if (copied_count() >= ARRAY_SIZE(copied_)) {
      // TODO(kasper): Report meaningful error.
      return false;
    }
    copied_[copied_count_++] = data;
  }
  return true;
}

bool MessageEncoder::encode_copy(Object* object, int tag) {
  ASSERT(tag == TAG_STRING || tag == TAG_BYTE_ARRAY);
  ASSERT(TAG_STRING_INLINE == TAG_STRING + 1);
  ASSERT(TAG_BYTE_ARRAY_INLINE == TAG_BYTE_ARRAY + 1);

  const uint8* source;
  int length = 0;
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
                               int size,
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
    *value = Smi::cast(object)->value();
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
  ObjectHeap* heap = process_->object_heap();
  for (unsigned i = 0; i < externals_count(); i++) {
    heap->remove_vm_finalizer(externals_[i]);
  }
}

void MessageDecoder::register_external(HeapObject* object, int length) {
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
      printf("[message decoder: wrong tison marker 0x%x - expected 0x%x]\n",
          marker, expected);
    }
    return mark_malformed();
  }
  int payload_size = read_cardinal();
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
      int length = read_cardinal();
      cursor_ += length;
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
  int length = read_cardinal();
  if (length == 0 && overflown()) return mark_malformed();
  Array* result = process_->object_heap()->allocate_array(length, Smi::zero());
  if (result == null) return mark_allocation_failed();
  for (int i = 0; i < length; i++) {
    Object* inner = decode_any();
    if (!success()) return inner;
    result->at_put(i, inner);
  }
  return result;
}

Object* MessageDecoder::decode_map() {
  int size = read_cardinal();
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
  for (int i = 0; i < size * 2; i++) {
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
  int length = read_cardinal();
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

bool MessageDecoder::decode_byte_array_external(void** data, int* length) {
  if (decoding_tison()) return false;
  int tag = read_uint8();
  if (tag == TAG_BYTE_ARRAY) {
    *length = read_cardinal();
    *data = read_pointer();
    return true;
  } else if (tag == TAG_BYTE_ARRAY_INLINE) {
    int encoded_length = *length = read_cardinal();
    void* copy = malloc(encoded_length);
    if (copy == null) return mark_allocation_failed();
    memcpy(copy, &buffer_[cursor_], encoded_length);
    *data = copy;
    return true;
  }
  return false;
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
  int cursor = cursor_;
  int next = cursor + sizeof(result);
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
  int cursor = cursor_;
  int next = cursor + sizeof(result);
  if (next <= size_) {
    memcpy(&result, &buffer_[cursor], sizeof(result));
  }
  cursor_ = next;
  return result;
}

uint64 MessageDecoder::read_uint64() {
  uint64 result = 0;
  int cursor = cursor_;
  int next = cursor + sizeof(result);
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
  process_ = process;
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

  SystemMessage* message = _new SystemMessage(type, process_->group()->id(), process_->id(), buffer);
  if (message == null) {
    if (discard) encoder.free_copied();
    free(buffer);
    return false;
  }
  scheduler_err_t result = vm_->scheduler()->send_message(pid, message);
  if (result == MESSAGE_OK) return true;
  message->free_data_but_keep_externals();
  if (discard) encoder.free_copied();
  delete message;
  return false;
}

Interpreter::Result ExternalSystemMessageHandler::run() {
  Process* process = process_;
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
  if (process_) {
    vm_->scheduler()->gc(process_, true, try_hard);
  }
}

}  // namespace toit
