// Copyright (C) 2026 Toit contributors.
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

#include "memory_capture.h"

#ifdef TOIT_MEMORY_CAPTURE

#include "encoder.h"
#include "heap.h"
#include "heap_report.h"
#include "objects_inline.h"
#include "os.h"
#include "process.h"
#include "process_group.h"
#include "program.h"
#include "scheduler.h"
#include "tags.h"
#include "utils.h"
#include "vm.h"

#ifdef TOIT_ESP32
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#endif

namespace toit {

// Every record of a capture is written as one line on stdout:
//
//   #TMC <base64 of: sequence number (u32 LE), record, crc32 (u32 LE)>
//
// A record is a UBJSON list whose first element is the record type. The
// CRC covers the sequence number and the record. Console noise between the
// lines is ignored by the host.
// Keep in sync with tools/memory-inspector/capture.toit.
static const int FORMAT_VERSION = 1;

enum RecordType {
  // [type, format version, VM version, platform, word size, reason].
  HEADER_RECORD = 0,
  // [type, name, value, name, value, ...]: the object layout constants.
  LAYOUT_RECORD = 1,
  // [type, tag, name, tag, name, ...]: the names of external struct tags.
  STRUCT_TAG_NAMES_RECORD = 2,
  // [type, program, uuid, program size, bytecodes address, bytecodes size,
  //  number of classes, null, true, false].
  PROGRAM_RECORD = 3,
  // [type, program, first class id, class bits (u16 LE)].
  CLASS_BITS_RECORD = 4,
  // [type, process id, group id, program, priority, heap bytes, external bytes].
  PROCESS_RECORD = 5,
  // [type, process id, kind, first index, values (words, LE)].
  ROOTS_RECORD = 6,
  // [type, process id, address, size].
  CHUNK_RECORD = 7,
  // [type, address, bytes].
  DATA_RECORD = 8,
  // [type, number of records before this one, complete, number of processes
  //  that could not be paused (and are missing from the capture)].
  END_RECORD = 9,
  // [type, name, name, ...]: the names of the malloc tags, indexed by tag.
  MALLOC_TAG_NAMES_RECORD = 10,
  // [type, name, total size, free size, largest free block].
  SYSTEM_HEAP_RECORD = 11,
  // [type, bytes]: allocations of the system heap; see $write_malloc_map.
  MALLOC_RECORD = 12,
  // [type, address, ...]: addresses in the blocks of the system heap that
  // the capture itself uses (its buffers and the stack of its thread).
  CAPTURE_BLOCKS_RECORD = 13,
};

enum RootKind {
  TASK_ROOT = 0,
  GLOBAL_ROOT = 1,
  EXTERNAL_ROOT = 2,
  FINALIZER_ROOT = 3,
};

// Maximum number of payload bytes in a single DATA record.
static const int DATA_CHUNK_SIZE = 768;
// Maximum number of words in a single ROOTS record.
static const int ROOTS_PER_RECORD = DATA_CHUNK_SIZE / WORD_SIZE;
// Maximum number of name/value pairs in a single LAYOUT or STRUCT_TAG_NAMES
// record.
static const int PAIRS_PER_RECORD = 16;

#define LAYOUT_CONSTANTS_DO(fn)                                                \
  fn("non-smi-tag-mask", Object::NON_SMI_TAG_MASK)                             \
  fn("heap-tag", Object::HEAP_TAG)                                             \
  fn("smi-tag-size", Object::SMI_TAG_SIZE)                                     \
  fn("class-tag-offset", HeapObject::CLASS_TAG_OFFSET)                         \
  fn("class-tag-bit-size", HeapObject::CLASS_TAG_BIT_SIZE)                     \
  fn("class-id-offset", HeapObject::CLASS_ID_OFFSET)                           \
  fn("array-tag", ARRAY_TAG)                                                   \
  fn("string-tag", STRING_TAG)                                                 \
  fn("instance-tag", INSTANCE_TAG)                                             \
  fn("oddball-tag", ODDBALL_TAG)                                               \
  fn("double-tag", DOUBLE_TAG)                                                 \
  fn("byte-array-tag", BYTE_ARRAY_TAG)                                         \
  fn("large-integer-tag", LARGE_INTEGER_TAG)                                   \
  fn("stack-tag", STACK_TAG)                                                   \
  fn("task-tag", TASK_TAG)                                                     \
  fn("free-list-region-tag", FREE_LIST_REGION_TAG)                             \
  fn("single-free-word-tag", SINGLE_FREE_WORD_TAG)                             \
  fn("promoted-track-tag", PROMOTED_TRACK_TAG)                                 \
  fn("class-bits-instance-size-offset", HeapObject::CLASS_ID_OFFSET)           \
  fn("class-bits-instance-size-mask", Program::INSTANCE_SIZE_MASK)             \
  fn("array-length-offset", Array::LENGTH_OFFSET)                              \
  fn("array-header-size", Array::HEADER_SIZE)                                  \
  fn("byte-array-length-offset", ByteArray::LENGTH_OFFSET)                     \
  fn("byte-array-header-size", ByteArray::HEADER_SIZE)                         \
  fn("byte-array-external-address-offset", ByteArray::EXTERNAL_ADDRESS_OFFSET) \
  fn("byte-array-external-tag-offset", ByteArray::EXTERNAL_TAG_OFFSET)         \
  fn("byte-array-external-size", ByteArray::EXTERNAL_SIZE)                     \
  fn("raw-byte-tag", RawByteTag)                                               \
  fn("string-internal-length-offset", String::INTERNAL_LENGTH_OFFSET)          \
  fn("string-internal-header-size", String::INTERNAL_HEADER_SIZE)              \
  fn("string-overhead", String::OVERHEAD)                                      \
  fn("string-sentinel", String::SENTINEL)                                      \
  fn("string-external-length-offset", String::EXTERNAL_LENGTH_OFFSET)          \
  fn("string-external-address-offset", String::EXTERNAL_ADDRESS_OFFSET)        \
  fn("string-external-object-size", String::EXTERNAL_OBJECT_SIZE)              \
  fn("instance-header-size", Instance::HEADER_SIZE)                            \
  fn("stack-length-offset", Stack::LENGTH_OFFSET)                              \
  fn("stack-top-offset", Stack::TOP_OFFSET)                                    \
  fn("stack-header-size", Stack::HEADER_SIZE)                                  \
  fn("double-size", Double::allocation_size())                                 \
  fn("large-integer-size", LargeInteger::allocation_size())                    \
  fn("free-list-region-size-offset", FreeListRegion::SIZE_OFFSET)              \
  fn("promoted-track-end-offset", PromotedTrack::END_OFFSET)                   \

// A fixed-size buffer for one record.
class RecordBuffer : public Buffer {
 public:
  static const int CAPACITY = 4 + DATA_CHUNK_SIZE + 64;

  virtual void put_byte(uint8 c) {
    if (position_ < CAPACITY) data_[position_] = c;
    position_++;
  }

  virtual bool has_overflow() { return position_ > CAPACITY; }

  void reset() { position_ = 0; }
  uint8* data() { return data_; }
  word size() const { return position_; }

 private:
  uint8 data_[CAPACITY + 4];  // Space for the CRC.
  word position_ = 0;
};

class MemoryCapture {
 public:
  explicit MemoryCapture(const char* reason) {
    strncpy(reason_, reason, sizeof(reason_) - 1);
    reason_[sizeof(reason_) - 1] = '\0';
  }

  void run();

 private:
  // Starts a record with the given number of fields after the type.
  Encoder* begin(RecordType type, int fields);
  void end();

  void write_header();
  void write_layout();
  void write_struct_tag_names();
#ifdef TOIT_ESP32
  void write_system_heap();
  void write_malloc_map();
#endif
  void write_program(Program* program);
  void write_process(Process* process);
  void write_roots(Process* process, RootKind kind, Object** roots, word count, word first_index);
  void write_chunk(Process* process, uword address, uword size);
  void write_words(Encoder* encoder, Object** words, word count);

  static void chunk_callback(void* context, Process* process, uword address, uword size) {
    reinterpret_cast<MemoryCapture*>(context)->write_chunk(process, address, size);
  }

  char reason_[64];
  RecordBuffer buffer_;
  Encoder encoder_ = Encoder(&buffer_);
  uint32 sequence_ = 0;
  bool complete_ = true;

  static const int MAX_PROGRAMS = 32;
  Program* written_programs_[MAX_PROGRAMS];
  int written_program_count_ = 0;

  friend class RootCollector;
};

Encoder* MemoryCapture::begin(RecordType type, int fields) {
  buffer_.reset();
  buffer_.put_uint8(sequence_ & 0xff);
  buffer_.put_uint8((sequence_ >> 8) & 0xff);
  buffer_.put_uint8((sequence_ >> 16) & 0xff);
  buffer_.put_uint8((sequence_ >> 24) & 0xff);
  encoder_.write_header(fields, type);
  return &encoder_;
}

void MemoryCapture::end() {
  if (buffer_.has_overflow()) FATAL("memory capture record overflow");
  word size = buffer_.size();
  uint8* data = buffer_.data();
  uint32 crc = Utils::crc32(0, data, size);
  for (int i = 0; i < 4; i++) data[size + i] = (crc >> (i * 8)) & 0xff;
  size += 4;

  static const char PREFIX[] = "#TMC ";
  const word prefix_length = sizeof(PREFIX) - 1;
  // Prefix, base64 content, and newline.
  char line[prefix_length + ((RecordBuffer::CAPACITY + 4 + 2) / 3) * 4 + 2];
  memcpy(line, PREFIX, prefix_length);
  word position = prefix_length;
  Base64Encoder base64;
  auto output = [&](uint8 c) { line[position++] = c; };
  base64.encode(data, size, output);
  base64.finish(output);
  line[position++] = '\n';
  // A single write keeps the line together, even if other threads print.
  fwrite(line, 1, position, stdout);
  fflush(stdout);
  sequence_++;
}

void MemoryCapture::write_header() {
  Encoder* encoder = begin(HEADER_RECORD, 5);
  encoder->write_int(FORMAT_VERSION);
  encoder->write_string(vm_git_version());
#ifdef TOIT_ESP32
  encoder->write_string(CONFIG_IDF_TARGET);
#else
  encoder->write_string("host");
#endif
  encoder->write_int(WORD_SIZE);
  encoder->write_string(reason_);
  end();
}

struct NamedValue {
  const char* name;
  word value;
};

void MemoryCapture::write_layout() {
  #define LAYOUT_ENTRY(name, value) { name, value },
  static const NamedValue constants[] = {
    LAYOUT_CONSTANTS_DO(LAYOUT_ENTRY)
  };
  #undef LAYOUT_ENTRY
  const int count = ARRAY_SIZE(constants);
  for (int first = 0; first < count; first += PAIRS_PER_RECORD) {
    int n = Utils::min(PAIRS_PER_RECORD, count - first);
    Encoder* encoder = begin(LAYOUT_RECORD, n * 2);
    for (int i = first; i < first + n; i++) {
      encoder->write_string(constants[i].name);
      encoder->write_int(constants[i].value);
    }
    end();
  }
}

void MemoryCapture::write_struct_tag_names() {
  #define TAG_ENTRY(name) { #name, name##Tag },
  static const NamedValue tags[] = {
    TAG_ENTRY(RawByte)
    TAG_ENTRY(NullStruct)
    TAG_ENTRY(MappedFile)
    NON_BLE_RESOURCE_CLASSES_DO(TAG_ENTRY)
    BLE_CLASSES_DO(TAG_ENTRY)
    BLE_READ_WRITE_CLASSES_DO(TAG_ENTRY)
    RESOURCE_GROUP_CLASSES_DO(TAG_ENTRY)
  };
  #undef TAG_ENTRY
  const int count = ARRAY_SIZE(tags);
  for (int first = 0; first < count; first += PAIRS_PER_RECORD) {
    int n = Utils::min(PAIRS_PER_RECORD, count - first);
    Encoder* encoder = begin(STRUCT_TAG_NAMES_RECORD, n * 2);
    for (int i = first; i < first + n; i++) {
      encoder->write_int(tags[i].value);
      encoder->write_string(tags[i].name);
    }
    end();
  }
}

#ifdef TOIT_ESP32

// Writes the names of the malloc tags, the sizes of the system heaps, and the
// allocations of the system heap.
void MemoryCapture::write_system_heap() {
  Encoder* encoder = begin(MALLOC_TAG_NAMES_RECORD, NUMBER_OF_MALLOC_TAGS);
  for (int i = 0; i < NUMBER_OF_MALLOC_TAGS; i++) {
    encoder->write_string(malloc_tag_name(i));
  }
  end();

  struct { const char* name; uint32 caps; } heaps[] = {
    { "internal", MALLOC_CAP_INTERNAL },
    { "external", MALLOC_CAP_SPIRAM },
  };
  for (auto heap : heaps) {
    uword total = heap_caps_get_total_size(heap.caps);
    if (total == 0) continue;
    Encoder* encoder = begin(SYSTEM_HEAP_RECORD, 4);
    encoder->write_string(heap.name);
    encoder->write_int(total);
    encoder->write_int(heap_caps_get_free_size(heap.caps));
    encoder->write_int(heap_caps_get_largest_free_block(heap.caps));
    end();
  }

  write_malloc_map();
}

// The allocations of the system heap are collected in windows, so the capture
// only needs a small buffer: every pass over the heap collects the allocations
// with the lowest addresses at or above the start of the window. The allocator
// lock is held while iterating, so the callback can neither allocate nor print.
struct MallocWindow {
  struct Entry {
    uword address;
    uword size;
    uint8 tag;
  };
  static const int CAPACITY = 64;
  Entry entries[CAPACITY];  // Sorted by address.
  int count = 0;
  uword start = 0;

  static bool callback(void* self, void* tag, void* address, uword size) {
    reinterpret_cast<MallocWindow*>(self)->add(reinterpret_cast<word>(tag), reinterpret_cast<uword>(address), size);
    return false;
  }

  void add(word tag, uword address, uword size) {
    if (address < start) return;
    if (count == CAPACITY && address >= entries[CAPACITY - 1].address) return;
    // Insertion sort. If the window is full, the last entry falls out.
    int i = (count == CAPACITY) ? CAPACITY - 1 : count++;
    while (i > 0 && entries[i - 1].address > address) {
      entries[i] = entries[i - 1];
      i--;
    }
    entries[i].address = address;
    entries[i].size = size;
    entries[i].tag = compute_allocation_type(tag);
  }
};

static void write_uleb128(Buffer* buffer, uword value) {
  while (value >= 0x80) {
    buffer->put_byte(0x80 | (value & 0x7f));
    value >>= 7;
  }
  buffer->put_byte(value);
}

static word uleb128_size(uword value) {
  word size = 1;
  while (value >= 0x80) {
    size++;
    value >>= 7;
  }
  return size;
}

// The malloc map is a sequence of entries (address as uleb128, size as
// uleb128, tag as byte), sorted by address and split over MALLOC records.
void MemoryCapture::write_malloc_map() {
  const int flags = ITERATE_ALL_ALLOCATIONS | ITERATE_UNALLOCATED;
  const int all_heaps = 0;
  MallocWindow* window = _new MallocWindow();
  if (window == null) {
    complete_ = false;
    return;
  }

  Encoder* encoder = begin(CAPTURE_BLOCKS_RECORD, 2);
  encoder->write_int(reinterpret_cast<uword>(window));
  encoder->write_int(reinterpret_cast<uword>(pxTaskGetStackStart(null)));
  end();

  uword window_start = 0;
  while (true) {
    window->count = 0;
    window->start = window_start;
    heap_caps_iterate_tagged_memory_areas(window, null, &MallocWindow::callback, flags, all_heaps);
    int index = 0;
    while (index < window->count) {
      // Find how many entries fit in a record.
      word bytes = 0;
      int limit = index;
      while (limit < window->count) {
        auto entry = &window->entries[limit];
        word entry_size = uleb128_size(entry->address) + uleb128_size(entry->size) + 1;
        if (bytes + entry_size > DATA_CHUNK_SIZE) break;
        bytes += entry_size;
        limit++;
      }
      Encoder* encoder = begin(MALLOC_RECORD, 1);
      encoder->write_byte_array_header(bytes);
      for (int i = index; i < limit; i++) {
        auto entry = &window->entries[i];
        write_uleb128(&buffer_, entry->address);
        write_uleb128(&buffer_, entry->size);
        buffer_.put_byte(entry->tag);
      }
      end();
      index = limit;
    }
    if (window->count < MallocWindow::CAPACITY) break;
    window_start = window->entries[MallocWindow::CAPACITY - 1].address + 1;
  }
  delete window;
}

#endif  // TOIT_ESP32

void MemoryCapture::write_program(Program* program) {
  for (int i = 0; i < written_program_count_; i++) {
    if (written_programs_[i] == program) return;
  }
  if (written_program_count_ < MAX_PROGRAMS) {
    written_programs_[written_program_count_++] = program;
  }

  word classes = program->class_bits.length();
  Encoder* encoder = begin(PROGRAM_RECORD, 9);
  encoder->write_int(reinterpret_cast<uword>(program));
  encoder->write_byte_array_header(UUID_SIZE);
  for (int i = 0; i < UUID_SIZE; i++) encoder->write_byte(program->snapshot_uuid()[i]);
  encoder->write_int(program->size_no_assets());
  encoder->write_int(reinterpret_cast<uword>(program->bytecodes.data()));
  encoder->write_int(program->bytecodes.length());
  encoder->write_int(classes);
  encoder->write_int(reinterpret_cast<uword>(program->null_object()));
  encoder->write_int(reinterpret_cast<uword>(program->true_object()));
  encoder->write_int(reinterpret_cast<uword>(program->false_object()));
  end();

  const word per_record = DATA_CHUNK_SIZE / 2;
  for (word first = 0; first < classes; first += per_record) {
    word count = Utils::min(per_record, classes - first);
    Encoder* encoder = begin(CLASS_BITS_RECORD, 3);
    encoder->write_int(reinterpret_cast<uword>(program));
    encoder->write_int(first);
    encoder->write_byte_array_header(count * 2);
    for (word i = first; i < first + count; i++) {
      uint16 bits = program->class_bits[i];
      encoder->write_byte(bits & 0xff);
      encoder->write_byte(bits >> 8);
    }
    end();
  }
}

void MemoryCapture::write_words(Encoder* encoder, Object** words, word count) {
  encoder->write_byte_array_header(count * WORD_SIZE);
  for (word i = 0; i < count; i++) {
    uword value = reinterpret_cast<uword>(words[i]);
    for (int j = 0; j < WORD_SIZE; j++) {
      encoder->write_byte((value >> (j * 8)) & 0xff);
    }
  }
}

void MemoryCapture::write_roots(Process* process, RootKind kind, Object** roots, word count, word first_index) {
  for (word offset = 0; offset < count; offset += ROOTS_PER_RECORD) {
    word n = Utils::min(static_cast<word>(ROOTS_PER_RECORD), count - offset);
    Encoder* encoder = begin(ROOTS_RECORD, 4);
    encoder->write_int(process->id());
    encoder->write_int(kind);
    encoder->write_int(first_index + offset);
    write_words(encoder, roots + offset, n);
    end();
  }
}

// Writes the roots a callback is called with as ROOTS records of one kind.
class RootCollector : public RootCallback {
 public:
  RootCollector(MemoryCapture* capture, Process* process, RootKind kind)
      : capture_(capture), process_(process), kind_(kind) {}

  virtual void do_roots(Object** roots, word length) {
    capture_->write_roots(process_, kind_, roots, length, index_);
    index_ += length;
  }

 private:
  MemoryCapture* capture_;
  Process* process_;
  RootKind kind_;
  word index_ = 0;
};

void MemoryCapture::write_chunk(Process* process, uword address, uword size) {
  Encoder* encoder = begin(CHUNK_RECORD, 3);
  encoder->write_int(process->id());
  encoder->write_int(address);
  encoder->write_int(size);
  end();
  for (uword offset = 0; offset < size; offset += DATA_CHUNK_SIZE) {
    uword n = Utils::min(static_cast<uword>(DATA_CHUNK_SIZE), size - offset);
    Encoder* encoder = begin(DATA_RECORD, 2);
    encoder->write_int(address + offset);
    encoder->write_byte_array_header(n);
    const uint8* bytes = reinterpret_cast<const uint8*>(address + offset);
    for (uword i = 0; i < n; i++) encoder->write_byte(bytes[i]);
    end();
  }
}

void MemoryCapture::write_process(Process* process) {
  Program* program = process->program();
  write_program(program);
  ObjectHeap* heap = process->object_heap();
  // Flush first, so the heap can be traversed and its size is exact.
  heap->flush();
  Encoder* encoder = begin(PROCESS_RECORD, 6);
  encoder->write_int(process->id());
  encoder->write_int(process->group()->id());
  encoder->write_int(reinterpret_cast<uword>(program));
  encoder->write_int(process->priority());
  encoder->write_int(heap->bytes_allocated() - heap->external_memory());
  encoder->write_int(heap->external_memory());
  end();

  Object* task = heap->task();
  write_roots(process, TASK_ROOT, &task, 1, 0);
  write_roots(process, GLOBAL_ROOT, heap->global_variables(), program->global_variables.length(), 0);
  RootCollector external_roots(this, process, EXTERNAL_ROOT);
  heap->iterate_external_roots(&external_roots);
  RootCollector finalizer_roots(this, process, FINALIZER_ROOT);
  heap->iterate_finalizer_roots(&finalizer_roots);
  heap->iterate_chunks(this, &chunk_callback);
}

void MemoryCapture::run() {
  write_header();
  write_layout();
  write_struct_tag_names();

  Scheduler* scheduler = VM::current()->scheduler();
  ProcessListFromScheduler paused;
  int not_paused = scheduler->pause_all_processes(&paused);
  if (not_paused > 0) complete_ = false;
#ifdef TOIT_ESP32
  write_system_heap();
#endif
  for (Process* process : paused) write_process(process);
  scheduler->resume_all_processes(&paused);

  Encoder* encoder = begin(END_RECORD, 3);
  encoder->write_int(sequence_);
  encoder->write_byte(complete_ ? 'T' : 'F');
  encoder->write_int(not_paused);
  end();
}

class MemoryCaptureThread : public Thread {
 public:
  explicit MemoryCaptureThread(const char* reason)
      : Thread("capture"), capture_(reason) {}

  bool is_done() const { return done_; }

 protected:
  virtual void entry() {
    capture_.run();
    done_ = true;
  }

 private:
  MemoryCapture capture_;
  volatile bool done_ = false;
};

// The running capture, or null. Protected by the global mutex.
static MemoryCaptureThread* capture_thread = null;

MemoryCaptureStart start_memory_capture(const char* reason) {
  Locker locker(OS::global_mutex());
  if (capture_thread != null) return MEMORY_CAPTURE_ALREADY_RUNNING;
  auto thread = _new MemoryCaptureThread(reason);
  if (thread == null) return MEMORY_CAPTURE_OUT_OF_MEMORY;
  if (!thread->spawn(6 * KB)) {
    delete thread;
    return MEMORY_CAPTURE_OUT_OF_MEMORY;
  }
  capture_thread = thread;
  return MEMORY_CAPTURE_STARTED;
}

bool is_memory_capture_done() {
  Locker locker(OS::global_mutex());
  if (capture_thread == null) return true;
  if (!capture_thread->is_done()) return false;
  capture_thread->join();
  delete capture_thread;
  capture_thread = null;
  return true;
}

}  // namespace toit

#endif  // TOIT_MEMORY_CAPTURE
