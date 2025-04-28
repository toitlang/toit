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
#include <driver/gpio.h>

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"


#include "../event_sources/system_esp32.h"
#include "../event_sources/ev_queue_esp32.h"

#if CONFIG_RMT_ISR_IRAM_SAFE || CONFIG_RMT_RECV_FUNC_IN_IRAM
#define RMT_MEM_ALLOC_CAPS      (MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)
#define RMT_IRAM_ATTR IRAM_ATTR
#else
#define RMT_MEM_ALLOC_CAPS      MALLOC_CAP_DEFAULT
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
}

esp_err_t RmtOut::disable() {
  if (buffer_ == null) return ESP_OK;

  ASSERT(encoder_ != null);
  free(buffer_);
  buffer_ = null;

  result = rmt_del_encoder(encoder_);
  encoder_ = null;

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
      }
      *data = kWriteState;
    }
  }
  return more;
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

PRIMITIVE(transmit) {
  ARGS(RmtResource, resource, Blob, items_bytes, int, loop_count, int, idle_level)
  if (!resource->is_tx()) FAIL(UNSUPPORTED);
  if (items_bytes.length() % 4 != 0) FAIL(INVALID_ARGUMENT);
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

  rmt_copy_encoder_config_t encoder_cfg = {};
  rmt_encoder_handle_t encoder_handle;
  esp_err_t err = rmt_new_copy_encoder(&encoder_cfg, &encoder_handle);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  out->set_encoder(encoder_handle);
  Defer del_encoder { [&] {
    if (!successful_return) {
      rmt_del_encoder(out->encoder());
      out->set_encoder(null);
    }
  } };

  rmt_transmit_config_t transmit_config = {
    .loop_count = loop_count,
    .flags = {
      .eot_level = static_cast<uint32>(idle_level),
      .queue_nonblocking = false,
    },
  };
  uint16 timestamp = timestamp_counter++;
  out->set_request_timestamp(timestamp);
  err = rmt_transmit(resource->handle(), encoder_handle, buffer, items_bytes.length(), &transmit_config);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  successful_return = true;
  return process->true_object();
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
  uint16 timestamp = timestamp_counter++;
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

} // namespace toit
#endif // TOIT_ESP32
