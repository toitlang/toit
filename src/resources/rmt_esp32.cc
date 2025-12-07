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

#include "../top.h"

#ifdef TOIT_ESP32

#include <soc/soc.h>
#include <driver/rmt_tx.h>
#include <driver/rmt_rx.h>
#include <driver/rmt_encoder.h>
#include <driver/gpio.h>
#include <esp_attr.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

#include "../event_sources/system_esp32.h"
#include "../event_sources/ev_queue_esp32.h"

#define SRAM_CAPS (MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)
#if CONFIG_RMT_ISR_IRAM_SAFE || CONFIG_RMT_RECV_FUNC_IN_IRAM
#define RMT_MEM_ALLOC_CAPS SRAM_CAPS
#define RMT_IRAM_ATTR IRAM_ATTR
#else
#define RMT_MEM_ALLOC_CAPS MALLOC_CAP_DEFAULT
#define RMT_IRAM_ATTR
#endif

namespace toit {

const int kReadState = 1 << 0;
const int kWriteState = 1 << 1;

typedef struct Event {
  word state;
} Event;

class RmtResourceGroup : public ResourceGroup {
 public:
  TAG(RmtResourceGroup);
  RmtResourceGroup(Process* process, EventSource* event_source)
    : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    if (data == kReadState || data == kWriteState) {
      state |= data;
    }
    return state;
  }
};

class RmtResource;
class RmtActivePatternEncoder;

class RmtInOut {
 public:
  virtual ~RmtInOut() {}
  virtual esp_err_t disable() = 0;
};

class RmtIn : public RmtInOut {
 public:
  ~RmtIn() override;

  esp_err_t disable() override;

  uint8* buffer() const { return buffer_; }
  void set_buffer(uint8* buffer) { buffer_ = buffer; }

  int received() const { return received_; }
  RMT_IRAM_ATTR void set_received(int received) {
    // No lock needed, as the interrupt is only active when nothing else
    // modifies the field from the outside.
    received_ = received;
  }

  uint16 request_timestamp() const { return request_timestamp_; }
  void set_request_timestamp(uint16 timestamp) { request_timestamp_ = timestamp; }

  /// Sets the timestamp (operation_counter) of when the last done-operation
  /// was called from the interrupt.
  /// If the done-timestamp is before the read-start-timestamp we know that
  /// it was for an earlier read-request.
  RMT_IRAM_ATTR void set_done_timestamp(uint16 timestamp) {
    // There is no need for locks, as setting the field is atomic.
    done_timestamp_ = timestamp;
  }

  uint16 done_timestamp() const { return done_timestamp_; }

 private:
  friend class RmtResource;

  uint8* buffer_ = null;
  int received_ = -1;

  uint16 request_timestamp_ = 0;
  uint16 done_timestamp_ = 0;
};

class RmtOut : public RmtInOut {
 public:
  ~RmtOut() override;

  esp_err_t disable() override;

  uint8* buffer() const { return buffer_; }
  void set_buffer(uint8* buffer) { buffer_ = buffer; }

  rmt_encoder_handle_t encoder() const { return encoder_; }
  void set_encoder(rmt_encoder_handle_t encoder) { encoder_ = encoder; }

  RmtActivePatternEncoder* active_pattern_encoder() const { return active_pattern_encoder_; }
  void set_active_pattern_encoder(RmtActivePatternEncoder* encoder) { active_pattern_encoder_ = encoder; }

  uint16 request_timestamp() const { return request_timestamp_; }
  void set_request_timestamp(uint16 timestamp) { request_timestamp_ = timestamp; }

  /// Sets the timestamp (operation_counter) of when the last done-operation
  /// was called from the interrupt.
  /// If the done-timestamp is before the read-start-timestamp we know that
  /// it was for an earlier read-request.
  RMT_IRAM_ATTR void set_done_timestamp(uint16 timestamp) {
    // There is no need for locks, as setting the field is atomic.
    done_timestamp_ = timestamp;
  }

  uint16 done_timestamp() const { return done_timestamp_; }

 private:
  friend class RmtResource;

  uint8* buffer_ = null;
  rmt_encoder_handle_t encoder_ = null;
  // May be null if we use the copy encoder.
  RmtActivePatternEncoder* active_pattern_encoder_ = null;

  uint16 request_timestamp_ = 0;
  uint16 done_timestamp_ = 0;
};

class RmtResource : public EventQueueResource {
 public:
  enum State {
    ENABLED,
    DISABLED,
  };

  TAG(RmtResource);
  RmtResource(RmtResourceGroup* group,
              rmt_channel_handle_t handle,
              bool is_tx,
              RmtInOut* in_out,
              QueueHandle_t queue)
      : EventQueueResource(group, queue)
      , handle_(handle)
      , is_tx_(is_tx)
      , in_out_(in_out) {}

  ~RmtResource() override;

  rmt_channel_handle_t handle() const { return handle_; }
  bool is_tx() const { return is_tx_; }

  bool receive_event(word* data) override;

  State state() const { return state_; }
  void set_state(State state) { state_ = state; }

  bool is_enabled() const { return state_ == ENABLED; }

  RmtIn* in() const {
    ASSERT(!is_tx_);
    return static_cast<RmtIn*>(in_out_);
  }

  RmtOut* out() const {
    ASSERT(is_tx_);
    return static_cast<RmtOut*>(in_out_);
  }

 private:
  rmt_channel_handle_t handle_;
  State state_ = DISABLED;
  bool is_tx_;
  RmtInOut* in_out_;
};

class RmtSyncManagerResource : public Resource {
 public:
  TAG(RmtSyncManagerResource);
  RmtSyncManagerResource(SimpleResourceGroup* group, rmt_sync_manager_handle_t handle)
      : Resource(group)
      , handle_(handle) {}

  ~RmtSyncManagerResource() override;

  rmt_sync_manager_handle_t handle() const { return handle_; }

 private:
  rmt_sync_manager_handle_t handle_;
};

class RmtPatternEncoder {
 public:
   explicit RmtPatternEncoder(uint8* data) : data_(data) {}

  void increase_ref() { ref_count_++; }
  void decrease_ref() {
    ref_count_--;
    if (ref_count_ == 0) delete this;
  }

  IRAM_ATTR uint8* data() const { return data_; }
  IRAM_ATTR bool msb() const { return data_[MSB_INDEX] != 0; }
  IRAM_ATTR int chunk_size() const { return data_[CHUNK_SIZE_INDEX]; }

  IRAM_ATTR void get_start_sequence(uint8** start_bytes, int* start_length) {
    *start_bytes = sequence(START_OFFSET_INDEX);
    *start_length = length(START_OFFSET_INDEX);
  }
  IRAM_ATTR void get_between_sequence(uint8** between_bytes, int* between_length) {
    *between_bytes = sequence(BETWEEN_OFFSET_INDEX);
    *between_length = length(BETWEEN_OFFSET_INDEX);
  }
  IRAM_ATTR void get_end_sequence(uint8** end_bytes, int* end_length) {
    *end_bytes = sequence(END_OFFSET_INDEX);
    *end_length = length(END_OFFSET_INDEX);
  }
  IRAM_ATTR void get_chunk_sequence(int chunk, uint8** chunk_bytes, int* chunk_length) {
    ASSERT(chunk < chunk_size());
    int offset_index = CHUNKS_OFFSET_INDEX + 2 * chunk;
    *chunk_bytes = sequence(offset_index);
    *chunk_length = length(offset_index);
  }

  int max_symbol_length() const;

  static bool validate(const uint8* buffer, int buffer_length);

 private:
  /// Layout:
  /// 1 byte of the bit-size of the chunks. Must be 1, 2, or 4.
  /// 1 byte to indicate whether the chunks should be processed MSB first.
  /// 2 bytes (little-endian): index into the data_ for the start sequence.
  /// 2 bytes (little-endian): index into the data_ for the between sequence.
  /// 2 bytes (little-endian): index into the data_ for the end sequence.
  /// 2 bytes (little-endian): for each chunk (up to 16 of them).
  /// 2 bytes (little-endian): pointing to the end of the data stream.
  /// Data for the offsets. Must be in the same order as the indexes (so we can compute
  /// the length of each sequence).
  static const int CHUNK_SIZE_INDEX = 0;
  static const int MSB_INDEX = 1;
  static const int START_OFFSET_INDEX = 2;
  static const int BETWEEN_OFFSET_INDEX = 4;
  static const int END_OFFSET_INDEX = 6;
  static const int CHUNKS_OFFSET_INDEX = 8;

  uint8* data_;
  int ref_count_ = 1;

  ~RmtPatternEncoder() {
    free(data_);
  }

  IRAM_ATTR int length(int offset_index) const {
    int start = data_[offset_index] | (data_[offset_index + 1] << 8);
    int end = data_[offset_index + 2] | (data_[offset_index + 3] << 8);
    return end - start;
  }
  IRAM_ATTR uint8* sequence(int offset_index) const {
    int offset = data_[offset_index] | (data_[offset_index + 1] << 8);
    return &data_[offset];
  }
};

/// An active encoder adds andex to the RmtPatternEncoder. This allows to reuse
/// the RmtPatternEncoder instance for different transmissions.
/// The ESP-IDF callback provides a `symbols_written` value that could be used
/// to compute the position, but that's inconvenient.
class RmtActivePatternEncoder {
 public:
  RmtActivePatternEncoder(int bit_length, RmtPatternEncoder* encoder)
      : encoder(encoder)
      , bit_pos(0)
      , has_encoded_start(false)
      , has_encoded_between(false)
      , has_encoded_end(false)
      , bit_length(bit_length) {
    encoder->increase_ref();
  }

  ~RmtActivePatternEncoder() {
    encoder->decrease_ref();
  }

  RmtPatternEncoder* encoder;
  uint bit_pos : 18;
  uint has_encoded_start : 1;
  uint has_encoded_between  : 1;
  uint has_encoded_end: 1;
  // The mask and its shift can be computed from the bit_pos, but we have enough space and this
  // makes the code easier.
  uint chunk_mask_shift: 3;
  uint chunk_mask : 8;
  // The size of the input in bits.
  // The ESP-IDF only gives us the size in bytes, but we might want to encode
  // parts of a byte.
  const int bit_length;
};

class RmtPatternEncoderResource : public Resource {
 public:
  TAG(RmtPatternEncoderResource);
  RmtPatternEncoderResource(SimpleResourceGroup* group, RmtPatternEncoder* encoder)
      : Resource(group)
      , encoder_(encoder) {
    encoder->increase_ref();
  }

  ~RmtPatternEncoderResource() override {
    encoder_->decrease_ref();
  }

  RmtPatternEncoder* encoder() const { return encoder_; }

 private:
  RmtPatternEncoder* encoder_;
};

// A counter for identifying operations.
// This counter is a replacement for timestamps which are hard to get inside an interrupt.
// Each operation that expects a response through an interrupt, increments and saves
// the counter.
// Similarly, functions that are called by interrupts tag their response with the counter.
// This way, we can know whether the interrupt was invoked before a new operation was started.
// See RmtIn::set_done_timestamp for why this is important.
static uint16 timestamp_counter = 0;

/// Whether t1 is before t2.
/// Takes wrap-around into account.
static bool is_timestamp_before_or_equal(uint16 t1, uint16 t2) {
  if (t1 <= t2) return (t2 - t1) < 0x3FFF;
  return (t1 - t2) > 0xFFFF - 0x3FFF;
}

RmtIn::~RmtIn() {
  free(buffer_);
}

esp_err_t RmtIn::disable() {
  if (buffer_ == null) return ESP_OK;

  free(buffer_);
  buffer_ = null;

  received_ = -1;

  return ESP_OK;
}

RmtOut::~RmtOut() {
 free(buffer_);
  if (encoder_ != null) FATAL_IF_NOT_ESP_OK(rmt_del_encoder(encoder_));
  if (active_pattern_encoder_ != null) delete active_pattern_encoder_;
}

esp_err_t RmtOut::disable() {
  if (buffer_ == null) return ESP_OK;

  ASSERT(encoder_ != null);
  free(buffer_);
  buffer_ = null;

  esp_err_t result = rmt_del_encoder(encoder_);
  encoder_ = null;

  if (active_pattern_encoder_ != null) {
    delete active_pattern_encoder_;
    active_pattern_encoder_ = null;
  }

  return result;
}

RmtResource::~RmtResource() {
  if (is_enabled()) rmt_disable(handle());
  FATAL_IF_NOT_ESP_OK(rmt_del_channel(handle_));
  vQueueDelete(queue());
  delete in_out_;
}

bool RmtResource::receive_event(word* data) {
  Event event;
  bool more = xQueueReceive(queue(), &event, 0);
  if (more) {
    if (event.state == kReadState) {
      *data = kReadState;
    } else {
      // Write is finished.
      auto request_timestamp = out()->request_timestamp();
      auto done_timestamp = out()->request_timestamp();
      if (is_timestamp_before_or_equal(request_timestamp, done_timestamp)) {
        // This is the event for the current request.
        // In theory it might have been for a previous request and was delayed
        // long enough that the next request also finished, but that's ok. We
        // still need to free the buffers.
        if (out()->buffer_ != null) {
          free(out()->buffer_);
          out()->buffer_ = null;
        }
        if (out()->encoder_ != null) {
          rmt_del_encoder(out()->encoder_);
          out()->encoder_ = null;
        }
        if (out()->active_pattern_encoder_ != null) {
          delete out()->active_pattern_encoder_;
          out()->active_pattern_encoder_ = null;
        }
      }
      *data = kWriteState;
    }
  }
  return more;
}

RmtSyncManagerResource::~RmtSyncManagerResource() {
  FATAL_IF_NOT_ESP_OK(rmt_del_sync_manager(handle_));
}

int RmtPatternEncoder::max_symbol_length() const {
  int result = 0;
  ASSERT(START_OFFSET_INDEX == 2)
  for(int offset_index = START_OFFSET_INDEX;
      offset_index < CHUNKS_OFFSET_INDEX + 2 * chunk_size();
      offset_index += 2) {
    int len = length(offset_index);
    if (len > result) result = len;
  }
  return result >> 2;
}

bool RmtPatternEncoder::validate(const uint8* buffer, int buffer_length) {
  if (buffer_length < CHUNKS_OFFSET_INDEX + 2) return false;
  int chunk_size = buffer[CHUNK_SIZE_INDEX];
  if (chunk_size != 1 && chunk_size != 2 && chunk_size != 4) return false;
  int msb = buffer[MSB_INDEX];
  if (msb != 0 && msb != 1) return false;

  ASSERT(START_OFFSET_INDEX == 2)
  // The last chunk-offset is followed by an offset that points to the end
  // of the data, so we know how long the last chunk is.
  int size_offset = CHUNKS_OFFSET_INDEX + 2 * (1 << chunk_size);
  int last_offset = size_offset + 2;
  for (int offset_index = START_OFFSET_INDEX;
      offset_index <= size_offset;
      offset_index += 2) {
    if (buffer_length < offset_index + 2) return false;
    int offset = buffer[offset_index] | (buffer[offset_index + 1] << 8);
    if (offset < last_offset) return false;
    if (offset > buffer_length) return false;
    // Each sequence must have a length that is a multiple of 4 (word-size).
    if (((offset - last_offset) & 0x3) != 0) return false;
    last_offset = offset;
  }
  return true;
}

RMT_IRAM_ATTR static bool tx_done(rmt_channel_t* channel,
                                  const rmt_tx_done_event_data_t* event,
                                  void* user_ctx) {
  auto resource = reinterpret_cast<RmtResource*>(user_ctx);
  auto queue = resource->queue();
  BaseType_t higher_was_woken;
  Event payload = {
    .state = kWriteState,
  };
  resource->out()->set_done_timestamp(timestamp_counter);

  // We don't use the return value of the queue-send. If the queue was full, then another
  // done-event is already queued. Since we updated the timestamp that's ok. The
  // user will know what to do.
  xQueueSendFromISR(queue, &payload, &higher_was_woken);
  return higher_was_woken == pdTRUE;
}

RMT_IRAM_ATTR static bool rx_done(rmt_channel_t* channel,
                                  const rmt_rx_done_event_data_t* event,
                                  void* user_ctx) {
  auto resource = reinterpret_cast<RmtResource*>(user_ctx);
  auto queue = resource->queue();
  BaseType_t higher_was_woken;
  Event payload = {
    .state = kReadState,
  };
  // Each symbol is 4 bytes long.
  resource->in()->set_received(static_cast<int>(event->num_symbols) * 4);
  resource->in()->set_done_timestamp(timestamp_counter);

  // We don't use the return value of the queue-send. If the queue was full, then another
  // done-event is already queued. Since we updated the timestamp that's ok. The
  // user will know what to do.
  xQueueSendFromISR(queue, &payload, &higher_was_woken);
  return higher_was_woken == pdTRUE;
}

IRAM_ATTR static size_t encoder_callback(const void* data,
                                         size_t data_size,
                                         size_t symbols_written,
                                         size_t symbols_free,
                                         rmt_symbol_word_t* symbols,
                                         bool* done,
                                         void* arg) {
  auto active = unvoid_cast<RmtActivePatternEncoder*>(arg);
  int bit_length = active->bit_length;
  ASSERT(data_size * 8 >= active->bit_length);
  auto encoder = active->encoder;
  int chunk_size = encoder->chunk_size();
  bool msb = encoder->msb();
  if (symbols_written == 0) {
    // Initialize/reset the active encoder.
    active->bit_pos = 0;
    active->has_encoded_start = false;
    active->has_encoded_between = false;
    active->has_encoded_end = false;
    int chunk_mask = (1 << chunk_size) - 1;
    int chunk_mask_shift = 0;
    if (msb) {
      chunk_mask_shift = 8 - chunk_size;
      chunk_mask <<= chunk_mask_shift;
    }
    active->chunk_mask_shift = chunk_mask_shift;
    active->chunk_mask = chunk_mask;
  }
  size_t total_encoded_symbols = 0;
  while (true) {
    // The bytes to write to the 'symbols' array.
    // We write the bytes at the end of the loop, to share that code.
    uint8* sequence_bytes = 0;
    int sequence_length = 0;

    // The following local variables may be modified.
    // They will be written back to the 'active' instance iif the sequence had space in
    // the target and was encoded.
    int bit_pos = active->bit_pos;
    bool has_encoded_start = active->has_encoded_start;
    bool has_encoded_between = active->has_encoded_between;
    bool has_encoded_end = active->has_encoded_end;
    int chunk_mask_shift = active->chunk_mask_shift;
    int chunk_mask = active->chunk_mask;

    if (bit_pos == 0 && !has_encoded_start) {
      // Start of transmission.
      encoder->get_start_sequence(&sequence_bytes, &sequence_length);
      has_encoded_start = true;
      has_encoded_between = true;
    } else if (bit_pos == bit_length && has_encoded_end) {
      *done = true;
      break;
    } else if (bit_pos == bit_length) {
      encoder->get_end_sequence(&sequence_bytes, &sequence_length);
      has_encoded_end = true;
    } else if ((bit_pos & 0x7) == 0 && !has_encoded_between) {
      encoder->get_between_sequence(&sequence_bytes, &sequence_length);
      has_encoded_between = true;
    } else {
      int index = bit_pos >> 3;
      uint8 byte = unvoid_cast<const uint8*>(data)[index];
      int chunk = (byte & chunk_mask) >> chunk_mask_shift;
      encoder->get_chunk_sequence(chunk, &sequence_bytes, &sequence_length);
      bit_pos += chunk_size;
      has_encoded_between = false;
      if (msb) {
        if (chunk_mask_shift == 0) {
          chunk_mask_shift = 8 - chunk_size;
          chunk_mask <<= chunk_mask_shift;
        } else {
          chunk_mask_shift -= chunk_size;
          chunk_mask >>= chunk_size;
        }
      } else {
        chunk_mask_shift += chunk_size;
        chunk_mask <<= chunk_size;
        if (chunk_mask > 0xFF) {
          chunk_mask_shift -= 8;
          chunk_mask >>= 8;
        }
      }
    }

    ASSERT((sequence_length & 0x3) == 0);
    size_t sequence_symbols_count = sequence_length >> 2;
    if (sequence_symbols_count > symbols_free) {
      break;
    }
    // The current sequence fits.
    // Copy it over and update the active instance.
    // The original 'memcpy' didn't work on esp32c3. We use a loop instead.
    // memcpy(symbols, sequence_bytes, sequence_length);
    //
    auto sequence_symbols = reinterpret_cast<rmt_symbol_word_t*>(sequence_bytes);
    for (int i = 0; i < sequence_symbols_count; i++) {
      symbols[i].val = sequence_symbols[i].val;
    }
    symbols = &symbols[sequence_symbols_count];
    symbols_free -= sequence_symbols_count;
    active->bit_pos = bit_pos;
    active->has_encoded_start = has_encoded_start;
    active->has_encoded_between = has_encoded_between;
    active->has_encoded_end = has_encoded_end;
    active->chunk_mask_shift = chunk_mask_shift;
    active->chunk_mask = chunk_mask;
    total_encoded_symbols += sequence_symbols_count;
  }
  return total_encoded_symbols;
}

MODULE_IMPLEMENTATION(rmt, MODULE_RMT);

PRIMITIVE(bytes_per_memory_block) {
  return Smi::from(SOC_RMT_MEM_WORDS_PER_CHANNEL * sizeof(word));
}

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  RmtResourceGroup* rmt = _new RmtResourceGroup(process, EventQueueEventSource::instance());
  if (!rmt) FAIL(MALLOC_FAILED);

  proxy->set_external_address(rmt);
  return proxy;
}

PRIMITIVE(channel_new) {
  ARGS(RmtResourceGroup, resource_group, int, pin_num, uint32, resolution, uint32, block_symbols, int, kind)

  if (block_symbols == 0) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  bool handed_to_resource = false;

  const int caps_flags = RMT_MEM_ALLOC_CAPS;
  auto resource_memory = heap_caps_malloc(sizeof(RmtResource), caps_flags);
  if (!resource_memory) FAIL(MALLOC_FAILED);
  Defer free_resource_memory { [&] { if (!handed_to_resource) free(resource_memory); } };

  bool is_tx = kind != 0;

  RmtInOut* in_out;
  if (is_tx) {
    auto out_memory = heap_caps_malloc(sizeof(RmtOut), caps_flags);
    if (!out_memory) FAIL(MALLOC_FAILED);
    in_out = new (out_memory) RmtOut();
  } else {
    auto in_memory = heap_caps_malloc(sizeof(RmtIn), caps_flags);
    if (!in_memory) FAIL(MALLOC_FAILED);
    in_out = new (in_memory) RmtIn();
  }
  Defer free_in_out { [&] { if (!handed_to_resource) delete in_out; } };

  // No need for a big queue. We only allow one read/write at a time.
  QueueHandle_t queue = xQueueCreate(1, sizeof(word));
  if (queue == null) FAIL(MALLOC_FAILED);
  Defer free_queue { [&] { if (!handed_to_resource) vQueueDelete(queue); } };

  rmt_channel_handle_t handle;
  esp_err_t err;
  if (is_tx) {
    bool open_drain = kind == 2;
    rmt_tx_channel_config_t cfg = {
      .gpio_num = static_cast<gpio_num_t>(pin_num),
      .clk_src = RMT_CLK_SRC_DEFAULT,
      .resolution_hz = resolution,
      .mem_block_symbols = static_cast<size_t>(block_symbols),
      .trans_queue_depth = 1,  // We only allow one active operation.
      .intr_priority = 0,
      .flags = {
        .invert_out = false,
        .with_dma = false,
        .io_loop_back = true,
        .io_od_mode = open_drain,
        .allow_pd = false,
      },
    };
    err = rmt_new_tx_channel(&cfg, &handle);
  } else {
    // Input.
    rmt_rx_channel_config_t cfg = {
      .gpio_num = static_cast<gpio_num_t>(pin_num),
      .clk_src = RMT_CLK_SRC_DEFAULT,
      .resolution_hz = resolution,
      .mem_block_symbols = static_cast<size_t>(block_symbols),
      .intr_priority = 0,
      .flags = {
        .invert_in = false,
        .with_dma = false,
        .io_loop_back = false,
        .allow_pd = false,
      },
    };

    err = rmt_new_rx_channel(&cfg, &handle);
  }
  if (err == ESP_ERR_NOT_FOUND) FAIL(ALREADY_IN_USE);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  Defer delete_channel { [&] { if (!handed_to_resource) rmt_del_channel(handle); } };

  RmtResource* resource = new (resource_memory) RmtResource(resource_group, handle, is_tx, in_out, queue);
  handed_to_resource = true;

  if (is_tx) {
    rmt_tx_event_callbacks_t callbacks = {
      .on_trans_done = tx_done,
    };
    err = rmt_tx_register_event_callbacks(handle, &callbacks, resource);
  } else {
    rmt_rx_event_callbacks_t callbacks = {
      .on_recv_done = rx_done,
    };
    err = rmt_rx_register_event_callbacks(handle, &callbacks, resource);
  }
  if (err != ESP_OK) {
    delete resource;
    return Primitive::os_error(err, process);
  }

  resource_group->register_resource(resource);
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(enable) {
  ARGS(RmtResource, resource)
  if (!resource->is_enabled()) {
    esp_err_t err = rmt_enable(resource->handle());
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }
  resource->set_state(RmtResource::ENABLED);
  return process->null_object();
}

PRIMITIVE(disable) {
  ARGS(RmtResource, resource)
  if (resource->is_enabled()) {
    esp_err_t err = rmt_disable(resource->handle());
    if (err != ESP_OK) return Primitive::os_error(err, process);

    if (resource->is_tx()) {
      err = resource->out()->disable();
    } else {
      err = resource->in()->disable();
    }
    FATAL_IF_NOT_ESP_OK(err);
  }
  resource->set_state(RmtResource::DISABLED);
  return process->null_object();
}

PRIMITIVE(channel_delete) {
  ARGS(RmtResourceGroup, resource_group, RmtResource, resource)
  resource_group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

static Object* transmit(Process* process,
                        RmtResource* resource,
                        Blob& items_bytes,
                        int loop_count,
                        int idle_level,
                        int bit_size = -1,
                        RmtPatternEncoderResource* pattern_encoder_resource = null) {
  if (!resource->is_tx()) FAIL(UNSUPPORTED);
  if (idle_level != 0 && idle_level != 1) FAIL(INVALID_ARGUMENT);


  auto out = resource->out();
  if (out->buffer() != null) {
    // Some operation is still in progress.
    return process->false_object();
  }
  ASSERT(out->encoder() == null);

  bool successful_return = false;

  // Make a copy that is owned by the resource.
  const int caps_flags = RMT_MEM_ALLOC_CAPS;
  uint8* buffer = unvoid_cast<uint8*>(heap_caps_malloc(items_bytes.length(), caps_flags));
  if (buffer == null) FAIL(MALLOC_FAILED);
  memcpy(buffer, items_bytes.address(), items_bytes.length());
  out->set_buffer(buffer);
  Defer free_buffer { [&] {
    if (!successful_return) {
      free(out->buffer());
      out->set_buffer(null);
    }
  } };

  rmt_encoder_handle_t encoder_handle = null;
  if (pattern_encoder_resource != null) {
    // Must be in SRAM since it's used from within an interrupt.
    auto encoder_memory = heap_caps_malloc(sizeof(RmtActivePatternEncoder), SRAM_CAPS);
    if (!encoder_memory) FAIL(ALLOCATION_FAILED);
    auto active_encoder = new (encoder_memory) RmtActivePatternEncoder(bit_size, pattern_encoder_resource->encoder());
    // The minimal chunk size where the encoder can guarantee that it can make progress is the
    // maximum length of all possible sequences.
    size_t min_chunk_size = pattern_encoder_resource->encoder()->max_symbol_length();
    rmt_simple_encoder_config_t encoder_cfg = {
      .callback = encoder_callback,
      .arg = active_encoder,
      .min_chunk_size = min_chunk_size,
    };
    esp_err_t err = rmt_new_simple_encoder(&encoder_cfg, &encoder_handle);
    if (err != ESP_OK) {
      delete active_encoder;
      return Primitive::os_error(err, process);
    }
    out->set_encoder(encoder_handle);
    out->set_active_pattern_encoder(active_encoder);
  } else {
    rmt_copy_encoder_config_t encoder_cfg = {};
    esp_err_t err = rmt_new_copy_encoder(&encoder_cfg, &encoder_handle);
    if (err != ESP_OK) return Primitive::os_error(err, process);
    out->set_encoder(encoder_handle);
  }
  Defer del_encoder { [&] {
    if (!successful_return) {
      rmt_del_encoder(out->encoder());
      out->set_encoder(null);
      if (out->active_pattern_encoder() != null) {
        delete out->active_pattern_encoder();
        out->set_active_pattern_encoder(null);
      }
    }
  } };

  rmt_transmit_config_t transmit_config = {
    .loop_count = loop_count,
    .flags = {
      .eot_level = static_cast<uint32>(idle_level),
      .queue_nonblocking = false,
    },
  };
  uint16 timestamp = ++timestamp_counter;
  out->set_request_timestamp(timestamp);
  esp_err_t err = rmt_transmit(resource->handle(), encoder_handle, buffer, items_bytes.length(), &transmit_config);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  successful_return = true;
  return process->true_object();
}

PRIMITIVE(transmit) {
  ARGS(RmtResource, resource, Blob, items_bytes, int, loop_count, int, idle_level)
  if (items_bytes.length() % 4 != 0) FAIL(INVALID_ARGUMENT);

  return transmit(process, resource, items_bytes, loop_count, idle_level);
}

PRIMITIVE(transmit_with_encoder) {
  ARGS(RmtResource, resource,
       Blob, items_bytes,
       int, loop_count,
       int, idle_level,
       int, bit_size,
       RmtPatternEncoderResource, pattern_encoder_resource)
  if (bit_size <= (items_bytes.length() - 1) * 8 || bit_size > items_bytes.length() * 8) FAIL(INVALID_ARGUMENT);
  if ((bit_size % pattern_encoder_resource->encoder()->chunk_size()) != 0) FAIL(INVALID_ARGUMENT);

  return transmit(process, resource, items_bytes, loop_count, idle_level, bit_size, pattern_encoder_resource);
}

PRIMITIVE(is_transmit_done) {
  ARGS(RmtResource, resource)
  if (!resource->is_tx()) FAIL(UNSUPPORTED);

  auto out = resource->out();
  return BOOL(out->buffer() == null);
}

PRIMITIVE(start_receive) {
  ARGS(RmtResource, resource, uint32, min_ns, uint32, max_ns, uint32, max_size)
  if (resource->is_tx()) FAIL(UNSUPPORTED);
  if (max_size % 4 != 0) FAIL(INVALID_ARGUMENT);
  if (!resource->is_enabled()) FAIL(INVALID_STATE);

  auto in = resource->in();
  if (in->buffer() != null) {
    // Read in progress.
    FAIL(INVALID_STATE);
  }

  bool successful_return = false;

  const int caps_flags = RMT_MEM_ALLOC_CAPS;
  uint8* buffer = unvoid_cast<uint8*>(heap_caps_malloc(max_size, caps_flags));
  if (buffer == null) FAIL(MALLOC_FAILED);
  in->set_buffer(buffer);
  in->set_received(-1);
  Defer free_buffer { [&] {
    if (!successful_return) {
      free(in->buffer());
      in->set_buffer(null);
    }
  } };

  rmt_receive_config_t cfg = {
    .signal_range_min_ns = min_ns,
    .signal_range_max_ns = max_ns,
    .flags = {
      // We don't allow partial reads. They are also not supported by all hardware.
      .en_partial_rx = false,
    },
  };
  uint16 timestamp = ++timestamp_counter;
  in->set_request_timestamp(timestamp);
  esp_err_t err = rmt_receive(resource->handle(), buffer, max_size, &cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  successful_return = true;
  return process->null_object();
}

PRIMITIVE(receive) {
  ARGS(RmtResource, resource)
  if (resource->is_tx()) FAIL(UNSUPPORTED);
  if (!resource->is_enabled()) FAIL(INVALID_STATE);

  auto in = resource->in();
  uint16 done_timestamp = in->done_timestamp();
  uint16 request_timestamp = in->request_timestamp();
  if (!is_timestamp_before_or_equal(request_timestamp, done_timestamp)) {
    // We don't have the data yet.
    return process->null_object();
  }

  auto bytes = in->buffer();
  int received = in->received();
  bytes = unvoid_cast<uint8*>(realloc(bytes, received));
  if (bytes == null) FAIL(MALLOC_FAILED);
  // In case we run out of memory for the external memory we need to store the
  // realloced buffer.
  in->set_buffer(bytes);

  bool dispose, clear;
  ByteArray* result = process->object_heap()->allocate_external_byte_array(received, bytes, dispose=true, clear=false);
  if (result == null) FAIL(ALLOCATION_FAILED);

  in->set_buffer(null);
  in->set_received(-1);

  return result;
}

PRIMITIVE(apply_carrier) {
  ARGS(RmtResource, resource, uint32, frequency, double, duty_cycle, bool, active_low, bool, always_on)

  rmt_carrier_config_t cfg = {
    .frequency_hz = frequency,
    .duty_cycle = static_cast<float>(duty_cycle),
    .flags = {
      .polarity_active_low = active_low,
      .always_on = always_on,
    },
  };

  esp_err_t err = rmt_apply_carrier(resource->handle(), &cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(sync_manager_new) {
  ARGS(SimpleResourceGroup, group, Array, channels)

  if (channels->length() > SOC_RMT_CHANNELS_PER_GROUP) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  rmt_channel_handle_t handles[SOC_RMT_CHANNELS_PER_GROUP];
  for (int i = 0; i < channels->length(); i++) {
    Object* o = channels->at(i);
    if (!is_byte_array(o)) FAIL(WRONG_OBJECT_TYPE);
    ByteArray* bytes = ByteArray::cast(o);
    if (!bytes->has_external_address() || bytes->external_tag() != RmtResourceTag) {
      FAIL(WRONG_OBJECT_TYPE);
    }
    RmtResource* resource = bytes->as_external<RmtResource>();
    if (!resource->is_tx()) FAIL(INVALID_ARGUMENT);
    handles[i] = resource->handle();
  }

  rmt_sync_manager_config_t cfg = {
    .tx_channel_array = handles,
    .array_size = static_cast<size_t>(channels->length()),
  };
  rmt_sync_manager_handle_t handle;
  esp_err_t err = rmt_new_sync_manager(&cfg, &handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  bool handed_to_resource = false;
  Defer del_sync { [&] { if (!handed_to_resource) rmt_del_sync_manager(handle); } };

  RmtSyncManagerResource* resource = _new RmtSyncManagerResource(group, handle);
  handed_to_resource = true;

  group->register_resource(resource);
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(sync_manager_delete) {
  ARGS(SimpleResourceGroup, group, RmtSyncManagerResource, resource)
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(sync_manager_reset) {
  ARGS(RmtSyncManagerResource, resource)
  esp_err_t err = rmt_sync_reset(resource->handle());
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(encoder_new) {
  ARGS(SimpleResourceGroup, group, Blob, bytes)
  if (bytes.length() == 0) FAIL(INVALID_ARGUMENT);
  if (!RmtPatternEncoder::validate(bytes.address(), bytes.length())) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // The encoder is called from interrupts and must be in SRAM.
  uint8* buffer = unvoid_cast<uint8*>(heap_caps_malloc(bytes.length(), SRAM_CAPS));
  if (!buffer) FAIL(MALLOC_FAILED);
  bool handed_to_encoder = false;
  Defer del_buffer { [&] { if (!handed_to_encoder) free(buffer); } };

  memcpy(buffer, bytes.address(), bytes.length());

  auto encoder_memory = heap_caps_malloc(sizeof(RmtPatternEncoder), SRAM_CAPS);
  if (!encoder_memory) FAIL(MALLOC_FAILED);
  auto encoder = new (encoder_memory) RmtPatternEncoder(buffer);
  handed_to_encoder = true;
  Defer decrease_encoder_ref { [&] {
    // Unconditionally decrease the ref-count. If the resource was constructed
    // properly, it increased the ref-count and the object stays alive.
    encoder->decrease_ref();
  } };

  auto resource = _new RmtPatternEncoderResource(group, encoder);
  if (!resource) FAIL(MALLOC_FAILED);

  group->register_resource(resource);
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(encoder_delete) {
  ARGS(SimpleResourceGroup, group, RmtPatternEncoderResource, resource)
  group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

} // namespace toit
#endif // TOIT_ESP32
