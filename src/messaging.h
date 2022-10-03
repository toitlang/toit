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
#include "interpreter.h"
#include "snapshot_bundle.h"

namespace toit {

class Message;
class Process;
class VM;

typedef LinkedFIFO<Message> MessageFIFO;

enum MessageType {
  MESSAGE_INVALID = 0,
  MESSAGE_MONITOR_NOTIFY = 1,
  MESSAGE_PENDING_FINALIZER = 2,
  MESSAGE_SYSTEM = 3,
};

enum MessageFormat {
  MESSAGE_FORMAT_IPC,
  MESSAGE_FORMAT_TISON,
};

enum {
  MESSAGING_PROCESS_MESSAGE_SIZE = 3,

  MESSAGING_ENCODING_MAX_NESTING      = 8,
  MESSAGING_ENCODING_MAX_EXTERNALS    = 8,
  MESSAGING_ENCODING_MAX_INLINED_SIZE = 128,
};

class Message : public MessageFIFO::Element {
 public:
  virtual ~Message() { }

  virtual MessageType message_type() const = 0;

  bool is_object_notify() const { return message_type() == MESSAGE_MONITOR_NOTIFY; }
  bool is_system() const { return message_type() == MESSAGE_SYSTEM; }
};

class SystemMessage : public Message {
 public:
  // Some system messages that are created from within the VM.
  enum Type {
    TERMINATED = 0,
    SPAWNED = 1,
  };

  SystemMessage(int type, int gid, int pid, uint8* data) : _type(type), _gid(gid), _pid(pid), _data(data) { }
  SystemMessage(int type, int gid, int pid) : _type(type), _gid(gid), _pid(pid), _data(null) { }
  virtual ~SystemMessage() override { free_data_and_externals(); }

  virtual MessageType message_type() const override { return MESSAGE_SYSTEM; }

  int type() const { return _type; }
  int gid() const { return _gid; }
  int pid() const { return _pid; }
  uint8* data() const { return _data; }

  void set_pid(int pid) { _pid = pid; }

  // Free the encoded buffer and but keep any external memory areas that it references.
  // This is used after succesfully decoding a message and thus taking ownership of such
  // external areas.
  void free_data_but_keep_externals() {
    free(_data);
    _data = null;
  }

  // Free the encoded buffer and all the external memory areas that it references.
  void free_data_and_externals();

 private:
  const int _type;
  const int _gid;  // The process group ID this message comes from.
  int _pid;  // The process ID this message comes from.
  uint8* _data;
};

class ObjectNotifyMessage : public Message {
 public:
  explicit ObjectNotifyMessage(ObjectNotifier* notifier)
      : _notifier(notifier)
      , _queued(false) {
  }

  virtual MessageType message_type() const override { return MESSAGE_MONITOR_NOTIFY; }

  bool is_queued() const { return _queued; }
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
  explicit MessageEncoder(uint8* buffer) : _buffer(buffer) { }
  MessageEncoder(Process* process, uint8* buffer)
      : MessageEncoder(process, buffer, MESSAGE_FORMAT_IPC) { }

  static void encode_process_message(uint8* buffer, uint8 value);

  unsigned size() const { return _cursor; }
  bool malloc_failed() const { return _malloc_failed; }

  void free_copied();
  void neuter_externals();

  bool encode(Object* object) { ASSERT(!encoding_tison()); return encode_any(object); }
  bool encode_byte_array_external(void* data, int length);

#ifndef TOIT_FREERTOS
  bool encode_arguments(char** argv, int argc);
  bool encode_bundles(SnapshotBundle system, SnapshotBundle application);
#endif

 protected:
  MessageEncoder(Process* process, uint8* buffer, MessageFormat format);

  bool encoding_for_size() const { return _buffer == null; }
  bool encoding_tison() const { return _format == MESSAGE_FORMAT_TISON; }
  unsigned copied_count() const { return _copied_count; }
  unsigned externals_count() const { return _externals_count; }

  bool encode_any(Object* object);

  void write_uint32(uint32 value);
  void write_cardinal(uword value);

 private:
  Process* const _process = null;
  Program* const _program = null;
  const MessageFormat _format = MESSAGE_FORMAT_IPC;

  uint8* const _buffer;  // The buffer is null when we're encoding for size.
  int _cursor = 0;
  int _nesting = 0;

  bool _malloc_failed = false;

  unsigned _copied_count = 0;
  void* _copied[MESSAGING_ENCODING_MAX_EXTERNALS];

  unsigned _externals_count = 0;
  ByteArray* _externals[MESSAGING_ENCODING_MAX_EXTERNALS];

  bool encode_array(Array* object, int from, int to);
  bool encode_byte_array(ByteArray* object);
  bool encode_copy(Object* object, int tag);
  bool encode_list(Instance* instance, int from, int to);
  bool encode_map(Instance* instance);

  void write_uint8(uint8 value) {
    if (!encoding_for_size()) _buffer[_cursor] = value;
    _cursor++;
  }

  void write_uint64(uint64 value);
  void write_pointer(void* value);
};

class TisonEncoder : public MessageEncoder {
 public:
  TisonEncoder(Process* process)
      : MessageEncoder(process, null, MESSAGE_FORMAT_TISON) { }
  TisonEncoder(Process* process, uint8* buffer, unsigned payload_size)
      : MessageEncoder(process, buffer, MESSAGE_FORMAT_TISON)
      , _payload_size(payload_size) {
    ASSERT(payload_size > 0);
  }

  ~TisonEncoder() {
    ASSERT(copied_count() == 0);
    ASSERT(externals_count() == 0);
  }

  unsigned payload_size() const { return _payload_size; }

  bool encode(Object* object);

 private:
   unsigned _payload_size = 0;
};

class MessageDecoder {
 public:
  explicit MessageDecoder(const uint8* buffer) : _buffer(buffer) { }
  MessageDecoder(Process* process, const uint8* buffer)
      : MessageDecoder(process, buffer, INT_MAX, MESSAGE_FORMAT_IPC) { }

  static bool decode_process_message(const uint8* buffer, int* value);

  bool success() const { return _status == DECODE_SUCCESS; }
  bool allocation_failed() const { return _status == DECODE_ALLOCATION_FAILED; }
  bool malformed_input() const { return _status == DECODE_MALFORMED_INPUT; }

  void register_external_allocations();
  void remove_disposing_finalizers();

  Object* decode() { ASSERT(!decoding_tison()); return decode_any(); }
  bool decode_byte_array_external(void** data, int* length);

  // Encoded messages may contain pointers to external areas allocated using
  // malloc. To deallocate such messages, we have to traverse them and free
  // all external areas before freeing the buffer itself.
  static void deallocate(uint8* buffer);

 protected:
  MessageDecoder(Process* process, const uint8* buffer, int size, MessageFormat format);

  bool decoding_tison() const { return _format == MESSAGE_FORMAT_TISON; }
  bool overflown() const { return _cursor > _size; }
  int remaining() const { return _size - _cursor; }
  unsigned externals_count() const { return _externals_count; }

  Object* decode_any();

  Object* mark_malformed() { _status = DECODE_MALFORMED_INPUT; return null; }
  Object* mark_allocation_failed() { _status = DECODE_ALLOCATION_FAILED; return null; }

  uword read_cardinal();
  uint32 read_uint32();

 private:
  enum Status {
    DECODE_SUCCESS,
    DECODE_ALLOCATION_FAILED,
    DECODE_MALFORMED_INPUT,
  };

  Process* const _process = null;
  Program* const _program = null;
  const uint8* const _buffer;
  const int _size = INT_MAX;
  const MessageFormat _format = MESSAGE_FORMAT_IPC;

  int _cursor = 0;
  Status _status = DECODE_SUCCESS;

  unsigned _externals_count = 0;
  HeapObject* _externals[MESSAGING_ENCODING_MAX_EXTERNALS];
  word _externals_sizes[MESSAGING_ENCODING_MAX_EXTERNALS];

  void register_external(HeapObject* object, int length);

  Object* decode_string(bool inlined);
  Object* decode_array();
  Object* decode_map();
  Object* decode_byte_array(bool inlined);
  Object* decode_double();
  Object* decode_large_integer();

  void deallocate();

  uint8 read_uint8() {
    int cursor = _cursor++;
    return (cursor < _size) ? _buffer[cursor] : 0;
  }

  uint64 read_uint64();
  uint8* read_pointer();
};

class TisonDecoder : public MessageDecoder {
 public:
  TisonDecoder(Process* process, const uint8* buffer, int length)
      : MessageDecoder(process, buffer, length, MESSAGE_FORMAT_TISON) { }

  ~TisonDecoder() {
    ASSERT(externals_count() == 0);
  }

  Object* decode();
};

class ExternalSystemMessageHandler : private ProcessRunner {
 public:
  ExternalSystemMessageHandler(VM* vm) : _vm(vm), _process(null) { }

  // Try to start the messaging handler. Returns true if successful and false
  // if starting it failed due to lack of memory.
  bool start();

  // Get the process id for this message handler. Returns -1 if the process
  // hasn't been started.
  int pid() const;

  // Callback for received messages.
  virtual void on_message(int sender, int type, void* data, int length) = 0;

  // Send a message to a specific receiver. Returns true if the data was sent or
  // false if an error occurred. If discard is true, the message is always discarded
  // even on failures; otherwise, only messages that are succesfully sent are taken
  // over by the receiver and must not be touched or deallocated by the sender.
  bool send(int receiver, int type, void* data, int length, bool discard = false);

  // Support for handling failed allocations. Return true from the callback
  // if you have cleaned up and want to retry the allocation. Returning false
  // causes the message to be discarded.
  virtual bool on_failed_allocation(int length) { return false; }

  // Try collecting garbage. If asked to try hard, the system will preempt running
  // processes and get them to stop before garbage collecting their heaps.
  void collect_garbage(bool try_hard);

 private:
  VM* _vm;
  Process* _process;

  // Called by the scheduler.
  virtual Interpreter::Result run() override;
};

}  // namespace toit
