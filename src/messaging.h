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
class MessageEncoder;
class Process;
class VM;

typedef LinkedFifo<Message> MessageFIFO;

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
  virtual ~Message() {}

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

  SystemMessage(int type, int gid, int pid, uint8* data);
  SystemMessage(int type, int gid, int pid, MessageEncoder* encoder);
  SystemMessage(int type, int gid, int pid) : type_(type), gid_(gid), pid_(pid), data_(null) {}
  virtual ~SystemMessage() override { free_data_and_externals(); }

  virtual MessageType message_type() const override { return MESSAGE_SYSTEM; }

  int type() const { return type_; }
  int gid() const { return gid_; }
  int pid() const { return pid_; }
  uint8* data() const { return data_; }

  void set_pid(int pid) { pid_ = pid; }

  // Free the encoded buffer and but keep any external memory areas that it references.
  // This is used after succesfully decoding a message and thus taking ownership of such
  // external areas.
  void free_data_but_keep_externals() {
    free(data_);
    data_ = null;
  }

  // Free the encoded buffer and all the external memory areas that it references.
  void free_data_and_externals();

 private:
  const int type_;
  const int gid_;  // The process group ID this message comes from.
  int pid_;  // The process ID this message comes from.
  uint8* data_;
};

class ObjectNotifyMessage : public Message {
 public:
  explicit ObjectNotifyMessage(ObjectNotifier* notifier)
      : notifier_(notifier)
      , queued_(false) {}

  virtual MessageType message_type() const override { return MESSAGE_MONITOR_NOTIFY; }

  bool is_queued() const { return queued_; }
  ObjectNotifier* object_notifier() const { return notifier_; }

  void mark_queued() {
    queued_ = true;
  }

  bool mark_dequeued() {
    queued_ = false;
    return notifier_ == null;
  }

  bool clear_object_notifier() {
    notifier_ = null;
    return !is_queued();
  }

 private:
  ObjectNotifier* notifier_;
  bool queued_;
};

/**
Takes ownership of the buffer.
If the buffer is null, it simulates an encoding, calculating only the size, but
  not causing any allocations.
If the buffer is not null then allocations are made, pointed to by the encoded
  message.  They will be freed by the destructor.  If a message is successfully
  constructed, take_buffer() should be called so that allocations (including
  the buffer) are not freed by the destructor.  It is then the responsibility of
  the Message's destructor to free memory.
*/
class MessageEncoder {
 public:
  explicit MessageEncoder(uint8* buffer) : buffer_(buffer) {}
  MessageEncoder(Process* process, uint8* buffer)
      : MessageEncoder(process, buffer, MESSAGE_FORMAT_IPC, true) {}
  ~MessageEncoder();

  static void encode_process_message(uint8* buffer, uint8 value);

  unsigned size() const { return cursor_; }
  bool malloc_failed() const { return malloc_failed_; }

  /**
  Some encoders can take over the data pointed to by external
    ByteArrays.  It is also possible that external buffers have
    been malloced, and are pointed at by the encoded message.
  When all encoding is complete and no retryable (allocation) failures have
    been encountered, this should be called.  It neuters the external byte
    arrays and forgets the allocated external buffers, which must now be freed
    by the receiver.
  Also takes ownership of the buffer away.
  */
  uint8* take_buffer();

  bool encode(Object* object) { ASSERT(!encoding_tison()); return encode_any(object); }
  bool encode_bytes_external(void* data, int length, bool free_on_failure = true);

#ifndef TOIT_FREERTOS
  bool encode_arguments(char** argv, int argc);
  bool encode_bundles(SnapshotBundle system, SnapshotBundle application);
#endif

  Object* create_error_object(Process* process);

 protected:
  MessageEncoder(Process* process, uint8* buffer, MessageFormat format, bool take_ownership_of_buffer);

  bool encoding_for_size() const { return buffer_ == null; }
  bool encoding_tison() const { return format_ == MESSAGE_FORMAT_TISON; }
  unsigned copied_count() const { return copied_count_; }
  unsigned externals_count() const { return externals_count_; }

  bool encode_any(Object* object);

  void write_uint32(uint32 value);
  void write_cardinal(uword value);

 private:
  Process* const process_ = null;
  Program* const program_ = null;
  const MessageFormat format_ = MESSAGE_FORMAT_IPC;

  // The buffer is null when we're encoding for size.
  // When encoding has completed, the buffer may be null because
  //   someone else has taken responsibility for it and the data
  //   it points at.
  uint8* buffer_;
  bool take_ownership_of_buffer_;
  int cursor_ = 0;
  int nesting_ = 0;
  int problematic_class_id_ = -1;
  bool nesting_too_deep_ = false;
  bool too_many_externals_ = false;

  bool malloc_failed_ = false;

  unsigned copied_count_ = 0;
  void* copied_[MESSAGING_ENCODING_MAX_EXTERNALS];

  unsigned externals_count_ = 0;
  ByteArray* externals_[MESSAGING_ENCODING_MAX_EXTERNALS];

  bool encode_array(Array* object, int from, int to);
  bool encode_byte_array(ByteArray* object);
  bool encode_copy(Object* object, int tag);
  bool encode_list(Instance* instance, int from, int to);
  bool encode_map(Instance* instance);

  void write_uint8(uint8 value) {
    if (!encoding_for_size()) buffer_[cursor_] = value;
    cursor_++;
  }

  void write_uint64(uint64 value);
  void write_pointer(void* value);

  friend class SystemMessage;
};

// Doesn't take ownership of the buffer.
class TisonEncoder : public MessageEncoder {
 public:
  TisonEncoder(Process* process)
      : MessageEncoder(process, null, MESSAGE_FORMAT_TISON, false) {}
  TisonEncoder(Process* process, uint8* buffer, unsigned payload_size)
      : MessageEncoder(process, buffer, MESSAGE_FORMAT_TISON, false)
      , payload_size_(payload_size) {
    ASSERT(payload_size > 0);
  }

  ~TisonEncoder() {
    ASSERT(copied_count() == 0);
    ASSERT(externals_count() == 0);
  }

  unsigned payload_size() const { return payload_size_; }

  bool encode(Object* object);

 private:
   unsigned payload_size_ = 0;
};

class MessageDecoder {
 public:
  explicit MessageDecoder(const uint8* buffer) : buffer_(buffer) {}
  MessageDecoder(Process* process, const uint8* buffer)
      : MessageDecoder(process, buffer, INT_MAX, MESSAGE_FORMAT_IPC) {}

  static bool decode_process_message(const uint8* buffer, int* value);

  bool success() const { return status_ == DECODE_SUCCESS; }
  bool allocation_failed() const { return status_ == DECODE_ALLOCATION_FAILED; }
  bool malformed_input() const { return status_ == DECODE_MALFORMED_INPUT; }

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

  bool decoding_tison() const { return format_ == MESSAGE_FORMAT_TISON; }
  bool overflown() const { return cursor_ > size_; }
  int remaining() const { return size_ - cursor_; }
  unsigned externals_count() const { return externals_count_; }

  Object* decode_any();

  Object* mark_malformed() { status_ = DECODE_MALFORMED_INPUT; return null; }
  Object* mark_allocation_failed() { status_ = DECODE_ALLOCATION_FAILED; return null; }

  uword read_cardinal();
  uint32 read_uint32();

 private:
  enum Status {
    DECODE_SUCCESS,
    DECODE_ALLOCATION_FAILED,
    DECODE_MALFORMED_INPUT,
  };

  Process* const process_ = null;
  Program* const program_ = null;
  const uint8* const buffer_;
  const int size_ = INT_MAX;
  const MessageFormat format_ = MESSAGE_FORMAT_IPC;

  int cursor_ = 0;
  Status status_ = DECODE_SUCCESS;

  unsigned externals_count_ = 0;
  HeapObject* externals_[MESSAGING_ENCODING_MAX_EXTERNALS];
  word externals_sizes_[MESSAGING_ENCODING_MAX_EXTERNALS];

  void register_external(HeapObject* object, int length);

  Object* decode_string(bool inlined);
  Object* decode_array();
  Object* decode_map();
  Object* decode_byte_array(bool inlined);
  Object* decode_double();
  Object* decode_large_integer();

  void deallocate();

  uint8 read_uint8() {
    int cursor = cursor_++;
    return (cursor < size_) ? buffer_[cursor] : 0;
  }

  uint64 read_uint64();
  uint8* read_pointer();
};

class TisonDecoder : public MessageDecoder {
 public:
  TisonDecoder(Process* process, const uint8* buffer, int length)
      : MessageDecoder(process, buffer, length, MESSAGE_FORMAT_TISON) {}

  ~TisonDecoder() {
    ASSERT(externals_count() == 0);
  }

  Object* decode();
};

class ExternalSystemMessageHandler : private ProcessRunner {
 public:
  ExternalSystemMessageHandler(VM* vm) : vm_(vm), process_(null) {}

  // Try to start the messaging handler. Returns true if successful and false
  // if starting it failed due to lack of memory.
  bool start(int priority = -1);

  // Get the process id for this message handler. Returns -1 if the process
  // hasn't been started.
  int pid() const;

  // Get the priority for this message handler. Returns -1 if the process
  // hasn't been started.
  int priority() const;

  // Set the priority of this message handler. Returns true if successful and
  // false if the process hasn't been started yet.
  bool set_priority(uint8 priority);

  // Callback for received messages.
  virtual void on_message(int sender, int type, void* data, int length) = 0;

  // Send a message to a specific pid, using Scheduler::send_message. Returns
  // true if the data was sent or false if an error occurred. The data is
  // assumed to be a malloced message.  If free_on_failure is true, the data is
  // always freed even on failures; otherwise, only messages that are
  // succesfully sent are taken over by the receiver and must not be touched or
  // deallocated by the sender.
  bool send(int pid, int type, void* data, int length, bool free_on_failure = false);

  // Support for handling failed allocations. Return true from the callback
  // if you have cleaned up and want to retry the allocation. Returning false
  // causes the message to be discarded.
  virtual bool on_failed_allocation(int length) { return false; }

  // Try collecting garbage. If asked to try hard, the system will preempt running
  // processes and get them to stop before garbage collecting their heaps.
  void collect_garbage(bool try_hard);

 private:
  VM* vm_;
  Process* process_;

  // Called by the scheduler.
  virtual Interpreter::Result run() override;
  virtual void set_process(Process* process) override;
};

}  // namespace toit
