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

#pragma once

#include "top.h"
#include "objects.h"
#include "heap.h"

namespace toit {

class Message;
class Process;

typedef LinkedFIFO<Message> MessageFIFO;

enum MessageType {
  MESSAGE_INVALID = 0,
  MESSAGE_OBJECT_NOTIFY = 1,
  MESSAGE_SYSTEM = 2,
};

enum {
  MESSAGING_TERMINATION_MESSAGE_SIZE = 3,

  MESSAGING_ENCODING_MAX_NESTING      = 4,
  MESSAGING_ENCODING_MAX_EXTERNALS    = 8,
  MESSAGING_ENCODING_MAX_INLINED_SIZE = 128,
};


class Message : public MessageFIFO::Element {
 public:
  virtual ~Message() { }

  virtual MessageType message_type() const = 0;

  bool is_object_notify() const { return message_type() == MESSAGE_OBJECT_NOTIFY; }
  bool is_system() const { return message_type() == MESSAGE_SYSTEM; }
};

class SystemMessage : public Message {
 public:
  // Some system messages that are created from within the VM.
  enum {
    TERMINATED = 0,
  };

  SystemMessage(int type, int gid, int pid, uint8_t* data, int length) : _type(type), _gid(gid), _pid(pid), _data(data), _length(length) { }
  SystemMessage(int type, int gid, int pid) : _type(type), _gid(gid), _pid(pid), _data(null), _length(0) { }
  ~SystemMessage() {
    free(_data);
  }

  MessageType message_type() const { return MESSAGE_SYSTEM; }

  int gid() const { return _gid; }
  int pid() const { return _pid; }
  int type() const { return _type; }

  uint8_t* data() const { return _data; }
  int length() const { return _length; }

  void set_pid(int pid) { _pid = pid; }

  void clear_data() {
    _data = null;
    _length = 0;
  }

 private:
  const int _type;
  const int _gid;  // The process group ID this message comes from.
  int _pid;  // The process ID this message comes from.

  uint8_t* _data;
  int _length;
};

class ObjectNotifyMessage : public Message {
 public:
  explicit ObjectNotifyMessage(ObjectNotifier* notifier)
      : _notifier(notifier)
      , _queued(false) {}
  ~ObjectNotifyMessage() {}

  bool is_queued() const { return _queued; }
  MessageType message_type() const { return MESSAGE_OBJECT_NOTIFY; }
  ObjectNotifier* object_notifier() const { return _notifier; }

  void mark_queued() {
    _queued = true;
  }

  bool mark_dequeued() {
    _queued = false;
    return _notifier == null;
  }

  bool clear_object_notifier() {
    _notifier = null;
    return !is_queued();
  }

 private:
  ObjectNotifier* _notifier;
  bool _queued;
};

class MessageEncoder {
 public:
  MessageEncoder(Process* process, uint8* buffer);

  static int termination_message_size();
  static void encode_termination_message(uint8* buffer, uint8 value);

  int size() const { return _cursor; }
  bool malloc_failed() const { return _malloc_failed; }

  void free_copied();
  void neuter_externals();

  bool encode(Object* object);

 private:
  Process* _process;
  Program* _program;
  uint8* _buffer;  // The buffer is null when we're encoding for size.
  int _cursor;
  int _nesting;

  bool _malloc_failed;

  unsigned _copied_count;
  void* _copied[MESSAGING_ENCODING_MAX_EXTERNALS];

  unsigned _externals_count;
  ByteArray* _externals[MESSAGING_ENCODING_MAX_EXTERNALS];

  bool encoding_for_size() const { return _buffer == null; }

  bool encode_string(String* object);
  bool encode_array(Array* object, int size);
  bool encode_byte_array(ByteArray* object);
  bool encode_copy(Object* object, int tag);

  void write_uint8(uint8 value) {
    if (!encoding_for_size()) _buffer[_cursor] = value;
    _cursor++;
  }

  void write_uint64(uint64 value);
  void write_pointer(void* value);
  void write_cardinal(uword value);

};

class MessageDecoder {
 public:
  MessageDecoder(Process* process, uint8* buffer);

  static bool decode_termination_message(uint8* buffer, int* value);

  bool allocation_failed() const { return _allocation_failed; }
  word external_allocations_size() const;

  void remove_disposing_finalizers();

  Object* decode();

 private:
  Process* _process;
  Program* _program;
  uint8* _buffer;
  int _cursor;

  bool _allocation_failed;

  // We keep track of the external allocation overhead to be able to
  // mimic the behavior of registering multiple external memory chunks
  // in one call to ObjectHeap::register_external_allocation().
  word _external_overhead;
  word _external_allocations;

  unsigned _externals_count;
  HeapObject* _externals[MESSAGING_ENCODING_MAX_EXTERNALS];

  void register_external(HeapObject* object, int length);

  Object* decode_string(bool inlined);
  Object* decode_array();
  Object* decode_byte_array(bool inlined);
  Object* decode_double();
  Object* decode_large_integer();

  uint8 read_uint8() { return _buffer[_cursor++]; }
  uint64 read_uint64();
  uint8* read_pointer();
  uword read_cardinal();
};

}  // namespace toit
