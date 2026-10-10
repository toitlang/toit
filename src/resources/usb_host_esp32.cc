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

// USB host: a single client that owns at most one device and offers
// control transfers plus IN and OUT transfers on bulk and interrupt
// endpoints. Hubs are not supported, so "at most one device" is also all
// the hardware can do. The IDF host stack is a global singleton, and so is
// the Host: current_host is the one resource that owns the stack's client.
//
// The IDF host stack is installed when the Host is created and
// uninstalled again when it goes away, which also hands the USB PHY back
// to USB Serial/JTAG. Uninstall only works in one particular order (stop
// the event pump, power the port off, free all devices, pump until
// ALL_FREE, uninstall); if it still fails the stack stays installed with
// its pump running, so the next Host can reuse it (and powers the port on
// again).
//
// Teardown waits for in-flight transfers and the client task with bounded
// waits. If a wait runs out, the IDF may still touch the transfers and the
// resource, so the resource is not freed: it stays current_host, marked
// stuck, with its client task still running so late completions are
// handled. The next Host creation retries the cleanup and fails with
// USB_HOST_STUCK if the transfers are still in flight (unplugging the
// device completes them). Worst case the teardown blocks for about 3 s:
// 1 s for the transfers, 1 s for the client task and 1 s for the
// uninstall.
//
// TODO(P4): the ESP32-P4 has two OTG controllers (high-speed UTMI and
// full-speed). Select the controller (usb_host_config_t.peripheral_map in
// newer IDFs), size the transfer buffers for 512-byte high-speed bulk
// packets, and check the PHY hand-back, which is S3-specific. Devices on
// both ports (or behind a hub) are still one Host: that needs the transfer
// state to move from the resource into a per-device object.

#include "../top.h"

#if defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_USB_HOST)

#include <atomic>

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include <usb/usb_host.h>
#include <esp_log.h>
#include <esp_timer.h>
#include <soc/soc_caps.h>
#if SOC_USB_SERIAL_JTAG_SUPPORTED
#include <hal/usb_serial_jtag_hal.h>
#endif

#include "../byte_ring.h"
#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"

#include "../event_sources/ev_queue_esp32.h"
#include "usb_host_esp32.h"

namespace toit {

static const char* kTag = "usb_host";

// State bits. Keep in sync with lib/usb/host.toit.
const uint32 kConnectedState = 1 << 0;
const uint32 kGoneState = 1 << 1;
const uint32 kControlDoneState = 1 << 2;
const uint32 kInDoneState = 1 << 3;
const uint32 kOutDoneState = 1 << 4;

// Events are accumulated as bits in the resource; the queue only carries
// wake-ups, so a full queue loses nothing (it already holds a wake-up).
const int kEventQueueSize = 2;
static_assert(kEventQueueSize <= USB_HOST_EVENT_QUEUE_SIZE,
              "Increase USB_HOST_EVENT_QUEUE_SIZE");

const int kSetupSize = sizeof(usb_setup_packet_t);
const int kControlDataSize = CONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE;
const int kTransferBufferSize = 512;

// The size the IDF usb_host_lib example uses. Measured peaks on the S3
// (2026-10-05, enumeration, transfers, teardown): about 1.2 KB for the lib
// task and 0.9 KB for the client task; the rest is headroom for IDF error
// logging, which formats on the calling task's stack.
const int kTaskStackSize = 4096;
const int kTaskPriority = 5;
// Bounded waits during teardown.
const int kTeardownWaitMs = 1000;
// How often a cancel is repeated while the transfer is still pending: the
// client task may resubmit a stream transfer just after a cancel.
const int64_t kRecancelUs = 10 * 1000;

class UsbHostResource;

static Object* transfer_error(Process* process, usb_transfer_status_t status);

struct Transfer {
  usb_transfer_t* transfer = null;
  UsbHostResource* resource = null;
  uint32 done_state = 0;
  volatile bool pending = false;
  bool is_in = false;
};

class UsbHostResourceGroup : public ResourceGroup {
 public:
  TAG(UsbHostResourceGroup);

  UsbHostResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  void tear_down() override;

  uint32_t on_event(Resource* r, word data, uint32_t state) override {
    return state | static_cast<uint32>(data);
  }
};

class UsbHostResource : public EventQueueResource {
 public:
  TAG(UsbHostResource);

  UsbHostResource(UsbHostResourceGroup* group, QueueHandle_t queue)
      : EventQueueResource(group, queue) {
    spinlock_initialize(&spinlock_);
  }

  ~UsbHostResource() override {
    free(stream_buffer_);
    vQueueDelete(queue());
  }

  // Tears down and deletes the resource, or parks it as a stuck
  // current_host if the IDF may still use it.
  void delete_or_mark_for_deletion() override;

  // Retries the teardown of a stuck host and deletes it if that works.
  // Must hold stack_lock.
  bool try_reclaim();

  // Returns null on success.
  Object* init(Process* process);

  bool receive_event(word* data) override {
    uint32 wake_up;
    if (!xQueueReceive(queue(), &wake_up, 0)) return false;
    *data = pending_events_.exchange(0);
    return true;
  }

  usb_host_client_handle_t client() const { return client_; }
  usb_device_handle_t device() const { return device_; }
  // Whether a device is open and usable: not being closed.
  bool has_device() const { return device_ != null && !device_closing_; }
  // Whether an earlier close_device didn't finish; the device is still
  // open on the IDF side.
  bool device_closing() const { return device_closing_; }

  Transfer* control() { return &control_; }
  Transfer* in() { return &in_; }
  Transfer* out() { return &out_; }

  // Takes the address of a device that was enumerated since the last
  // call. Returns 0 if none.
  uint8 take_new_device_address();

  esp_err_t open_device(uint8 address);
  // Returns false if a transfer did not complete or the IDF did not close
  // the device; the device then stays open and device_closing() is true.
  bool close_device();

  // Cancels the transfer in flight on the endpoint, if any, and waits for
  // it. Returns false if it did not complete.
  bool cancel(uint8 endpoint);

  // After a transfer failed with STALL, ERROR or OVERFLOW the IDF leaves
  // the endpoint halted and refuses further submits. Clears it, so the
  // endpoint can be used again (the device side of a stall is cleared by
  // the client with CLEAR_FEATURE). Call once the transfer is no longer
  // pending.
  void clear_halt(Transfer* t);

  bool is_claimed(int number) const { return (claimed_interfaces_ & (1u << number)) != 0; }
  esp_err_t claim_interface(int number, int alt);
  esp_err_t release_interface(int number);

  // Streaming IN: the in_ transfer is resubmitted by the client task as
  // soon as it completes, into a buffer, so reading doesn't depend on Toit
  // being scheduled. Packet boundaries are lost.
  bool is_streaming() const { return stream_buffer_ != null; }
  // Each transfer asks for submit_size bytes (a multiple of the packet
  // size, at most kTransferBufferSize).
  Object* stream_start(Process* process, uint8 endpoint, int submit_size, int capacity);
  // Copies up to 'max' buffered bytes into a new byte array. Returns null
  // if nothing is buffered and the stream is still running.
  Object* stream_read(Process* process, int max);
  // Stops the stream and waits for its transfer. Returns false if the
  // transfer did not complete; the stream then stays allocated.
  bool stream_stop();

  bool is_pending(Transfer* t) {
    portENTER_CRITICAL(&spinlock_);
    bool result = t->pending;
    portEXIT_CRITICAL(&spinlock_);
    return result;
  }

  // Fills in and submits the transfer, which is pending until its callback
  // runs. Endpoint 0 is the control endpoint.
  esp_err_t submit(Transfer* t, uint8 endpoint, int num_bytes);

  // Called from the client task.
  void on_client_event(const usb_host_client_event_msg_t* msg);
  void on_transfer_done(Transfer* t);
  void on_stream_done();

  bool should_stop() const { return stop_; }
  void client_task_exited() { xSemaphoreGive(client_done_); }

 private:
  // Frees the stream buffer of a stopped stream.
  void stream_free();
  // Halts, flushes and clears the endpoint, which completes its pending
  // transfer with CANCELED.
  void cancel_now(uint8 endpoint);
  // Waits until none of the transfers is pending, repeating the cancel of
  // pending IN and OUT transfers (the client task may resubmit a stream
  // transfer just after a cancel). Control transfers cannot be canceled;
  // they complete when the device answers or goes away. Returns false
  // after kTeardownWaitMs.
  bool wait_idle(Transfer* const* transfers, int count);
  // Whether in_ should be submitted for the next stream chunk: the stream
  // is running and there is room. Must hold spinlock_.
  bool stream_should_submit();
  // Submits in_ for the next stream chunk; the caller has set it pending.
  // A failure ends the stream with an error.
  void stream_resubmit();

  // Closes the device and stops the client task. Returns false if a
  // transfer or the client task did not finish; the client task then keeps
  // running, so the IDF can still complete the transfers.
  bool quiesce();
  // Frees the IDF objects. Must be quiesced and hold stack_lock.
  void release();

  void post(uint32 events) {
    pending_events_.fetch_or(events);
    uint32 wake_up = 0;
    xQueueSend(queue(), &wake_up, 0);
  }

  // How far init got, so teardown undoes exactly that.
  bool client_registered_ = false;
  bool client_task_running_ = false;
  // Guards new_device_address_, the transfers' pending flags and the
  // stream flags, which the client task writes. Not stream_ring_.
  spinlock_t spinlock_;
  // State bits posted by the client task, not yet picked up by
  // receive_event.
  std::atomic<uint32> pending_events_{0};
  usb_host_client_handle_t client_ = null;
  // The open device, or null.
  usb_device_handle_t device_ = null;
  // Set while close_device runs, and after it failed.
  bool device_closing_ = false;
  // Set by the NEW_DEV event, taken by take_new_device_address.
  uint8 new_device_address_ = 0;
  // Bit i set: interface i is claimed and must be released on close.
  uint32 claimed_interfaces_ = 0;
  // Tells the client task to exit; it gives client_done_ when it does.
  volatile bool stop_ = false;
  SemaphoreHandle_t client_done_ = null;
  // One preallocated transfer per kind, so at most one of each is in
  // flight.
  Transfer control_;
  Transfer in_;
  Transfer out_;
  // The client task produces into stream_ring_, stream_read consumes.
  // stream_status_ holds the first error.
  uint8* stream_buffer_ = null;
  ByteRing stream_ring_;
  int stream_submit_size_ = 0;
  // Set when the stream must not resubmit any more.
  bool stream_stopping_ = false;
  usb_transfer_status_t stream_status_ = USB_TRANSFER_STATUS_COMPLETED;
};

// Created during static initialization, so it exists before any Host does.
static StaticSemaphore_t stack_lock_buffer;
static SemaphoreHandle_t stack_lock = xSemaphoreCreateMutexStatic(&stack_lock_buffer);

// All of the following is guarded by stack_lock.
static bool stack_installed = false;
// The open Host, or a closed one whose teardown got stuck.
static UsbHostResource* current_host = null;
static bool current_host_stuck = false;
static bool lib_task_running = false;
static volatile bool lib_stop = false;
static SemaphoreHandle_t lib_done = null;

// When a bounded teardown wait that starts now gives up.
static int64_t teardown_deadline() {
  return esp_timer_get_time() + static_cast<int64_t>(kTeardownWaitMs) * 1000;
}

static void lib_task(void* arg) {
  while (!lib_stop) {
    uint32_t flags = 0;
    // Enumerated devices are deliberately never freed when the last client
    // goes away: a freed device is not re-enumerated until it is physically
    // reconnected, and the next client wants to find it in the address list.
    // No timeout needed: stop_lib_task wakes us with usb_host_lib_unblock,
    // which gives a semaphore, so a wake-up before we block is not lost.
    usb_host_lib_handle_events(portMAX_DELAY, &flags);
  }
  xSemaphoreGive(lib_done);
  vTaskDelete(null);
}

// Must hold stack_lock.
static bool start_lib_task() {
  ASSERT(!lib_task_running);
  lib_stop = false;
  // Drop a give from an earlier task that stopped too late.
  xSemaphoreTake(lib_done, 0);
  if (xTaskCreatePinnedToCore(lib_task, "usb_lib", kTaskStackSize, null, kTaskPriority, null, tskNO_AFFINITY) != pdPASS) {
    return false;
  }
  lib_task_running = true;
  return true;
}

// Must hold stack_lock. Returns false if the task did not stop. It then
// keeps running.
static bool stop_lib_task() {
  if (!lib_task_running) return true;
  lib_stop = true;
  usb_host_lib_unblock();
  if (xSemaphoreTake(lib_done, pdMS_TO_TICKS(kTeardownWaitMs)) != pdTRUE) {
    // lib_stop stays set: the task may have read it already and exit any
    // moment. reap_lib_task picks that up.
    ESP_LOGE(kTag, "Lib task did not stop");
    return false;
  }
  lib_task_running = false;
  return true;
}

// Must hold stack_lock. Notices a lib task that stopped after stop_lib_task
// gave up waiting for it.
static void reap_lib_task() {
  if (lib_task_running && xSemaphoreTake(lib_done, 0) == pdTRUE) lib_task_running = false;
}

bool usb_host_lock_phy() {
  xSemaphoreTake(stack_lock, portMAX_DELAY);
  // The stack owns the PHY from usb_host_install to usb_host_uninstall.
  return stack_installed;
}

void usb_host_unlock_phy() {
  xSemaphoreGive(stack_lock);
}

// Must hold stack_lock, and no client may be registered.
static void uninstall_stack() {
  if (!stack_installed) return;
  reap_lib_task();
  if (!stop_lib_task()) return;
  usb_host_lib_set_root_port_power(false);
  esp_err_t err = usb_host_device_free_all();
  int64_t deadline = teardown_deadline();
  bool all_free = err == ESP_OK;
  err = ESP_ERR_INVALID_STATE;
  while (esp_timer_get_time() < deadline) {
    uint32_t flags = 0;
    usb_host_lib_handle_events(pdMS_TO_TICKS(10), &flags);
    if (flags & USB_HOST_LIB_EVENT_FLAGS_ALL_FREE) all_free = true;
    if (!all_free) continue;
    err = usb_host_uninstall();
    if (err == ESP_OK) break;
  }
  if (err == ESP_OK) {
    stack_installed = false;
#if SOC_USB_SERIAL_JTAG_SUPPORTED && USB_SERIAL_JTAG_LL_EXT_PHY_SUPPORTED
    // usb_del_phy leaves the shared PHY routed to the OTG controller; hand
    // it back to USB Serial/JTAG, the boot-time owner.
    usb_serial_jtag_hal_phy_set_external(null, false);
#endif
    return;
  }
  ESP_LOGE(kTag, "usb_host_uninstall failed (%s), keeping the stack installed", esp_err_to_name(err));
  if (!start_lib_task()) ESP_LOGE(kTag, "Could not restart the lib task");
}

// Must hold stack_lock.
static esp_err_t ensure_stack_installed() {
  if (!stack_installed) {
    usb_host_config_t host_config = {};
    host_config.skip_phy_setup = false;
    host_config.intr_flags = ESP_INTR_FLAG_LEVEL1;
    esp_err_t err = usb_host_install(&host_config);
    // INVALID_STATE means the IDF already has the stack installed although
    // we don't think so. Adopt it rather than failing until reboot.
    if (err == ESP_ERR_INVALID_STATE) {
      ESP_LOGW(kTag, "Adopting an already installed host stack");
    } else if (err != ESP_OK) {
      return err;
    }
    stack_installed = true;
  }
  reap_lib_task();
  if (!lib_task_running) {
    if (lib_done == null) lib_done = xSemaphoreCreateBinary();
    if (lib_done == null || !start_lib_task()) {
      uninstall_stack();
      return ESP_ERR_NO_MEM;
    }
  }
  // A failed uninstall leaves the root port powered off, and an adopted
  // stack may have it off too. Does nothing (INVALID_STATE) if it is on.
  usb_host_lib_set_root_port_power(true);
  return ESP_OK;
}

static void client_task(void* arg) {
  auto resource = unvoid_cast<UsbHostResource*>(arg);
  while (!resource->should_stop()) {
    // quiesce wakes us with usb_host_client_unblock; see lib_task.
    usb_host_client_handle_events(resource->client(), portMAX_DELAY);
  }
  resource->client_task_exited();
  vTaskDelete(null);
}

static void client_event_callback(const usb_host_client_event_msg_t* msg, void* arg) {
  unvoid_cast<UsbHostResource*>(arg)->on_client_event(msg);
}

static void transfer_callback(usb_transfer_t* transfer) {
  auto t = unvoid_cast<Transfer*>(transfer->context);
  t->resource->on_transfer_done(t);
}

void UsbHostResource::on_client_event(const usb_host_client_event_msg_t* msg) {
  switch (msg->event) {
    case USB_HOST_CLIENT_EVENT_NEW_DEV: {
      portENTER_CRITICAL(&spinlock_);
      new_device_address_ = msg->new_dev.address;
      portEXIT_CRITICAL(&spinlock_);
      post(kConnectedState);
      break;
    }
    case USB_HOST_CLIENT_EVENT_DEV_GONE:
      // Toit closes the device; pending transfers complete with NO_DEVICE.
      post(kGoneState);
      break;
  }
}

void UsbHostResource::on_transfer_done(Transfer* t) {
  if (t == &in_ && is_streaming()) {
    on_stream_done();
    return;
  }
  portENTER_CRITICAL(&spinlock_);
  t->pending = false;
  portEXIT_CRITICAL(&spinlock_);
  uint32 events = t->done_state;
  // The transfer can report the unplug before the DEV_GONE event arrives.
  if (t->transfer->status == USB_TRANSFER_STATUS_NO_DEVICE) events |= kGoneState;
  post(events);
}

uint8 UsbHostResource::take_new_device_address() {
  portENTER_CRITICAL(&spinlock_);
  uint8 address = new_device_address_;
  new_device_address_ = 0;
  portEXIT_CRITICAL(&spinlock_);
  if (address != 0) return address;
  // The device may have been enumerated before we registered.
  uint8 addresses[1];
  int count = 0;
  usb_host_device_addr_list_fill(1, addresses, &count);
  return count > 0 ? addresses[0] : 0;
}

esp_err_t UsbHostResource::open_device(uint8 address) {
  ASSERT(device_ == null);
  esp_err_t err = usb_host_device_open(client_, address, &device_);
  if (err != ESP_OK) device_ = null;
  return err;
}

void UsbHostResource::cancel_now(uint8 endpoint) {
  // Halt and flush complete the pending transfer with CANCELED; clear
  // makes the endpoint usable again.
  esp_err_t err = usb_host_endpoint_halt(device_, endpoint);
  if (err == ESP_OK) err = usb_host_endpoint_flush(device_, endpoint);
  if (err == ESP_OK) err = usb_host_endpoint_clear(device_, endpoint);
  if (err != ESP_OK) ESP_LOGE(kTag, "Cancel on endpoint 0x%02x failed: %s", endpoint, esp_err_to_name(err));
}

bool UsbHostResource::wait_idle(Transfer* const* transfers, int count) {
  int64_t deadline = teardown_deadline();
  int64_t next_cancel = 0;
  while (true) {
    bool all_done = true;
    for (int i = 0; i < count; i++) {
      if (is_pending(transfers[i])) all_done = false;
    }
    if (all_done) return true;
    int64_t now = esp_timer_get_time();
    if (now >= deadline) {
      for (int i = 0; i < count; i++) {
        Transfer* t = transfers[i];
        if (is_pending(t)) ESP_LOGE(kTag, "Transfer on endpoint 0x%02x did not complete", t->transfer->bEndpointAddress);
      }
      return false;
    }
    if (now >= next_cancel) {
      for (int i = 0; i < count; i++) {
        Transfer* t = transfers[i];
        if (t != &control_ && is_pending(t)) cancel_now(t->transfer->bEndpointAddress);
      }
      next_cancel = now + kRecancelUs;
    }
    vTaskDelay(1);
  }
}

esp_err_t UsbHostResource::submit(Transfer* t, uint8 endpoint, int num_bytes) {
  usb_transfer_t* transfer = t->transfer;
  transfer->num_bytes = num_bytes;
  transfer->bEndpointAddress = endpoint;
  transfer->device_handle = device_;
  transfer->flags = 0;
  portENTER_CRITICAL(&spinlock_);
  t->pending = true;
  portEXIT_CRITICAL(&spinlock_);
  esp_err_t err = endpoint == 0
      ? usb_host_transfer_submit_control(client_, transfer)
      : usb_host_transfer_submit(transfer);
  if (err != ESP_OK) {
    portENTER_CRITICAL(&spinlock_);
    t->pending = false;
    portEXIT_CRITICAL(&spinlock_);
  }
  return err;
}

bool UsbHostResource::cancel(uint8 endpoint) {
  Transfer* t = (endpoint & 0x80) != 0 ? &in_ : &out_;
  if (!is_pending(t) || t->transfer->bEndpointAddress != endpoint) return true;
  return wait_idle(&t, 1);
}

void UsbHostResource::clear_halt(Transfer* t) {
  usb_transfer_status_t status = t->transfer->status;
  if (status != USB_TRANSFER_STATUS_STALL &&
      status != USB_TRANSFER_STATUS_ERROR &&
      status != USB_TRANSFER_STATUS_OVERFLOW) {
    return;
  }
  if (t == &control_ || !has_device()) return;
  uint8 endpoint = t->transfer->bEndpointAddress;
  esp_err_t err = usb_host_endpoint_clear(device_, endpoint);
  if (err != ESP_OK) ESP_LOGW(kTag, "Clearing endpoint 0x%02x failed: %s", endpoint, esp_err_to_name(err));
}

bool UsbHostResource::stream_should_submit() {
  if (stream_stopping_ || stream_status_ != USB_TRANSFER_STATUS_COMPLETED) return false;
  // Also called by the consumer, but only while in_ is idle: the client
  // task then doesn't push, and the spinlock makes its last push visible.
  return stream_ring_.free_space() >= stream_submit_size_;
}

void UsbHostResource::stream_resubmit() {
  if (usb_host_transfer_submit(in_.transfer) == ESP_OK) return;
  portENTER_CRITICAL(&spinlock_);
  in_.pending = false;
  stream_status_ = USB_TRANSFER_STATUS_ERROR;
  portEXIT_CRITICAL(&spinlock_);
}

void UsbHostResource::on_stream_done() {
  usb_transfer_t* transfer = in_.transfer;
  uint32 events = kInDoneState;
  if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
    // stream_should_submit made sure the chunk fits.
    stream_ring_.push(transfer->data_buffer, transfer->actual_num_bytes);
  }
  portENTER_CRITICAL(&spinlock_);
  if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) {
    stream_status_ = transfer->status;
    if (transfer->status == USB_TRANSFER_STATUS_NO_DEVICE) events |= kGoneState;
  }
  // A single write, so close_device never sees the transfer idle while
  // it is about to be resubmitted.
  bool submit = stream_should_submit();
  in_.pending = submit;
  portEXIT_CRITICAL(&spinlock_);
  if (submit) stream_resubmit();
  post(events);
}

Object* UsbHostResource::stream_start(Process* process, uint8 endpoint, int submit_size, int capacity) {
  if (is_pending(&in_) || is_streaming()) FAIL(ALREADY_IN_USE);
  // The IDF checks that the size is a multiple of the packet size.
  if (submit_size <= 0 || submit_size > kTransferBufferSize) FAIL(INVALID_ARGUMENT);
  if (capacity < submit_size) FAIL(OUT_OF_RANGE);
  auto buffer = unvoid_cast<uint8*>(malloc(capacity));
  if (buffer == null) FAIL(MALLOC_FAILED);
  portENTER_CRITICAL(&spinlock_);
  stream_buffer_ = buffer;
  stream_ring_.init(buffer, capacity);
  stream_submit_size_ = submit_size;
  stream_stopping_ = false;
  stream_status_ = USB_TRANSFER_STATUS_COMPLETED;
  portEXIT_CRITICAL(&spinlock_);
  esp_err_t err = submit(&in_, endpoint, submit_size);
  if (err != ESP_OK) {
    stream_free();
    return Primitive::os_error(err, process);
  }
  return null;
}

Object* UsbHostResource::stream_read(Process* process, int max) {
  // Read the status first: data pushed before an error is then visible.
  portENTER_CRITICAL(&spinlock_);
  usb_transfer_status_t status = stream_status_;
  portEXIT_CRITICAL(&spinlock_);
  word available = stream_ring_.available();
  if (available == 0) {
    if (status != USB_TRANSFER_STATUS_COMPLETED) {
      // The stream is over (no resubmit after an error); the endpoint
      // should work for the next stream or transfer.
      clear_halt(&in_);
      return transfer_error(process, status);
    }
    return process->null_object();
  }
  // Only stream_read removes data, so at least 'length' bytes stay
  // available while we allocate.
  word length = Utils::min(available, static_cast<word>(max));
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  stream_ring_.pop(ByteArray::Bytes(result).address(), length);
  portENTER_CRITICAL(&spinlock_);
  // The client task stops submitting when the buffer is full; restart it.
  bool submit = !in_.pending && stream_should_submit();
  if (submit) in_.pending = true;
  portEXIT_CRITICAL(&spinlock_);
  if (submit) stream_resubmit();
  return result;
}

bool UsbHostResource::stream_stop() {
  if (!is_streaming()) return true;
  portENTER_CRITICAL(&spinlock_);
  stream_stopping_ = true;
  portEXIT_CRITICAL(&spinlock_);
  Transfer* t = &in_;
  if (!wait_idle(&t, 1)) return false;
  stream_free();
  return true;
}

void UsbHostResource::stream_free() {
  portENTER_CRITICAL(&spinlock_);
  uint8* buffer = stream_buffer_;
  stream_buffer_ = null;
  portEXIT_CRITICAL(&spinlock_);
  free(buffer);
}

bool UsbHostResource::close_device() {
  if (device_ == null) return true;
  device_closing_ = true;
  // Harmless if there is no stream; stream_start resets it.
  portENTER_CRITICAL(&spinlock_);
  stream_stopping_ = true;
  portEXIT_CRITICAL(&spinlock_);
  Transfer* transfers[] = { &control_, &in_, &out_ };
  if (!wait_idle(transfers, ARRAY_SIZE(transfers))) return false;
  if (is_streaming()) stream_free();
  for (int i = 0; i < 32; i++) {
    if ((claimed_interfaces_ & (1u << i)) == 0) continue;
    esp_err_t err = release_interface(i);
    if (err != ESP_OK) ESP_LOGE(kTag, "Releasing interface %d failed: %s", i, esp_err_to_name(err));
  }
  esp_err_t err = usb_host_device_close(client_, device_);
  if (err != ESP_OK) {
    ESP_LOGE(kTag, "usb_host_device_close failed: %s", esp_err_to_name(err));
    return false;
  }
  device_ = null;
  device_closing_ = false;
  return true;
}

esp_err_t UsbHostResource::claim_interface(int number, int alt) {
  esp_err_t err = usb_host_interface_claim(client_, device_, number, alt);
  if (err == ESP_OK) claimed_interfaces_ |= 1u << number;
  return err;
}

esp_err_t UsbHostResource::release_interface(int number) {
  // The IDF keeps an endpoint busy until the client task has finished with
  // its completion, a moment after our callback ran, and refuses the
  // release until then.
  int64_t deadline = teardown_deadline();
  esp_err_t err;
  while (true) {
    err = usb_host_interface_release(client_, device_, number);
    if (err != ESP_ERR_INVALID_STATE || esp_timer_get_time() >= deadline) break;
    vTaskDelay(1);
  }
  if (err == ESP_OK) claimed_interfaces_ &= ~(1u << number);
  return err;
}

static Object* error_string(Process* process, const char* name) {
  String* str = process->allocate_string(name);
  if (str == null) FAIL(ALLOCATION_FAILED);
  return Primitive::mark_as_error(str);
}

Object* UsbHostResource::init(Process* process) {
  xSemaphoreTake(stack_lock, portMAX_DELAY);
  if (current_host != null) {
    bool in_use = !current_host_stuck;
    bool stuck = current_host_stuck && !current_host->try_reclaim();
    if (in_use || stuck) {
      xSemaphoreGive(stack_lock);
      if (in_use) FAIL(ALREADY_IN_USE);
      return error_string(process, "USB_HOST_STUCK");
    }
  }
  esp_err_t err = ensure_stack_installed();
  if (err == ESP_OK) {
    usb_host_client_config_t client_config = {};
    client_config.is_synchronous = false;
    client_config.max_num_event_msg = 5;
    client_config.async.client_event_callback = client_event_callback;
    client_config.async.callback_arg = this;
    err = usb_host_client_register(&client_config, &client_);
    if (err == ESP_OK) {
      current_host = this;
      client_registered_ = true;
    } else {
      uninstall_stack();
    }
  }
  xSemaphoreGive(stack_lock);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  struct { Transfer* t; int size; uint32 state; } specs[] = {
    { &control_, kSetupSize + kControlDataSize, kControlDoneState },
    { &in_, kTransferBufferSize, kInDoneState },
    { &out_, kTransferBufferSize, kOutDoneState },
  };
  for (auto& spec : specs) {
    err = usb_host_transfer_alloc(spec.size, 0, &spec.t->transfer);
    if (err != ESP_OK) return Primitive::os_error(err, process);
    spec.t->resource = this;
    spec.t->done_state = spec.state;
    spec.t->transfer->callback = transfer_callback;
    spec.t->transfer->context = spec.t;
  }

  client_done_ = xSemaphoreCreateBinary();
  if (client_done_ == null) FAIL(MALLOC_FAILED);

  if (xTaskCreatePinnedToCore(client_task, "usb_client", kTaskStackSize, this, kTaskPriority, null, tskNO_AFFINITY) != pdPASS) {
    FAIL(MALLOC_FAILED);
  }
  client_task_running_ = true;
  return null;
}

bool UsbHostResource::quiesce() {
  if (!client_task_running_) return true;
  if (!close_device()) return false;
  stop_ = true;
  usb_host_client_unblock(client_);
  if (xSemaphoreTake(client_done_, pdMS_TO_TICKS(kTeardownWaitMs)) != pdTRUE) {
    ESP_LOGE(kTag, "Client task did not stop");
    return false;
  }
  client_task_running_ = false;
  return true;
}

void UsbHostResource::release() {
  if (client_done_ != null) vSemaphoreDelete(client_done_);
  Transfer* transfers[] = { &control_, &in_, &out_ };
  for (auto t : transfers) {
    if (t->transfer != null) usb_host_transfer_free(t->transfer);
  }
  if (client_registered_) {
    esp_err_t err = usb_host_client_deregister(client_);
    // A client that can't be deregistered keeps the stack installed; the
    // uninstall below then fails and leaves it running for the next Host.
    if (err != ESP_OK) ESP_LOGE(kTag, "usb_host_client_deregister failed: %s", esp_err_to_name(err));
    uninstall_stack();
  }
  if (current_host == this) {
    current_host = null;
    current_host_stuck = false;
  }
}

void UsbHostResource::delete_or_mark_for_deletion() {
  bool quiet = quiesce();
  xSemaphoreTake(stack_lock, portMAX_DELAY);
  if (!quiet) {
    // The owning process may be going away, and the notifier lives on its
    // heap. Nobody waits on this resource any more.
    resource_group()->event_source()->delete_resource_monitor(this);
    current_host_stuck = true;
    xSemaphoreGive(stack_lock);
    ESP_LOGE(kTag, "USB host teardown stuck; retrying when the next Host is created");
    return;
  }
  release();
  xSemaphoreGive(stack_lock);
  delete this;
}

bool UsbHostResource::try_reclaim() {
  // The client task kept running, so transfers that finished in the
  // meantime are no longer pending.
  if (!quiesce()) return false;
  release();
  delete this;
  return true;
}

void UsbHostResourceGroup::tear_down() {
  // Unregistering drains the event queue, which must not keep refilling.
  // If the stream doesn't stop, close_device retries.
  for (auto r : resources()) static_cast<UsbHostResource*>(r)->stream_stop();
  ResourceGroup::tear_down();
}

static Object* transfer_error(Process* process, usb_transfer_status_t status) {
  const char* name;
  switch (status) {
    case USB_TRANSFER_STATUS_ERROR: name = "USB_TRANSFER_ERROR"; break;
    case USB_TRANSFER_STATUS_TIMED_OUT: name = "USB_TRANSFER_TIMED_OUT"; break;
    case USB_TRANSFER_STATUS_CANCELED: name = "USB_TRANSFER_CANCELED"; break;
    case USB_TRANSFER_STATUS_STALL: name = "USB_TRANSFER_STALL"; break;
    case USB_TRANSFER_STATUS_OVERFLOW: name = "USB_TRANSFER_OVERFLOW"; break;
    case USB_TRANSFER_STATUS_NO_DEVICE: name = "USB_NO_DEVICE"; break;
    default: name = "USB_TRANSFER_FAILED"; break;
  }
  return error_string(process, name);
}

// Copies the UTF-16LE payload of a string descriptor, or returns null if
// the device has none.
static Object* string_descriptor(Process* process, const usb_str_desc_t* desc) {
  if (desc == null || desc->bLength < 2) return process->null_object();
  // Drop the odd byte of a malformed descriptor: UTF-16 needs pairs.
  int length = (desc->bLength - 2) & ~1;
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  memcpy(ByteArray::Bytes(result).address(), desc->wData, length);
  return result;
}

MODULE_IMPLEMENTATION(usb_host, MODULE_USB_HOST)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new UsbHostResourceGroup(process, EventQueueEventSource::instance());
  if (group == null) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(UsbHostResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  QueueHandle_t queue = xQueueCreate(kEventQueueSize, sizeof(uint32));
  if (queue == null) FAIL(MALLOC_FAILED);

  auto resource = _new UsbHostResource(group, queue);
  if (resource == null) {
    vQueueDelete(queue);
    FAIL(MALLOC_FAILED);
  }
  // From here on the resource owns the queue.

  Object* result = resource->init(process);
  if (result != null) {
    resource->delete_or_mark_for_deletion();
    return result;
  }

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(UsbHostResource, resource);
  // Unregistering drains the event queue, which must not keep refilling.
  // If the stream doesn't stop, close_device retries.
  resource->stream_stop();
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

// Opens the connected device, if any. Returns null or
// [idVendor, idProduct, bcdDevice, bMaxPacketSize0, bDeviceClass,
//  bDeviceSubClass, bDeviceProtocol, config-descriptor, manufacturer,
//  product, serial-number], where the last three are the UTF-16LE payloads
// of the string descriptors, or null.
PRIMITIVE(device_open) {
  ARGS(UsbHostResource, resource);

  Array* result = process->object_heap()->allocate_array(11, process->null_object());
  if (result == null) FAIL(ALLOCATION_FAILED);

  // Finish the close of a device whose transfers were stuck.
  if (resource->device_closing() && !resource->close_device()) {
    return error_string(process, "USB_TRANSFER_STUCK");
  }
  if (!resource->has_device()) {
    uint8 address = resource->take_new_device_address();
    if (address == 0) return process->null_object();
    esp_err_t err = resource->open_device(address);
    // The device may have been unplugged again since it was enumerated:
    // NOT_FOUND once it is freed, INVALID_STATE while it is gone but not
    // yet freed.
    if (err == ESP_ERR_NOT_FOUND || err == ESP_ERR_INVALID_STATE) return process->null_object();
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  usb_device_handle_t device = resource->device();
  const usb_device_desc_t* device_desc;
  esp_err_t err = usb_host_get_device_descriptor(device, &device_desc);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  const usb_config_desc_t* config_desc;
  err = usb_host_get_active_config_descriptor(device, &config_desc);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  usb_device_info_t info;
  err = usb_host_device_info(device, &info);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  ByteArray* config = process->allocate_byte_array(config_desc->wTotalLength);
  if (config == null) FAIL(ALLOCATION_FAILED);
  memcpy(ByteArray::Bytes(config).address(), config_desc, config_desc->wTotalLength);
  Object* strings[] = {
    string_descriptor(process, info.str_desc_manufacturer),
    string_descriptor(process, info.str_desc_product),
    string_descriptor(process, info.str_desc_serial_num),
  };
  for (auto string : strings) {
    if (Primitive::is_error(string)) return string;
  }

  result->at_put(0, Smi::from(device_desc->idVendor));
  result->at_put(1, Smi::from(device_desc->idProduct));
  result->at_put(2, Smi::from(device_desc->bcdDevice));
  result->at_put(3, Smi::from(device_desc->bMaxPacketSize0));
  result->at_put(4, Smi::from(device_desc->bDeviceClass));
  result->at_put(5, Smi::from(device_desc->bDeviceSubClass));
  result->at_put(6, Smi::from(device_desc->bDeviceProtocol));
  result->at_put(7, config);
  result->at_put(8, strings[0]);
  result->at_put(9, strings[1]);
  result->at_put(10, strings[2]);
  return result;
}

PRIMITIVE(device_close) {
  ARGS(UsbHostResource, resource);
  if (!resource->close_device()) return error_string(process, "USB_TRANSFER_STUCK");
  return process->null_object();
}

PRIMITIVE(claim_interface) {
  ARGS(UsbHostResource, resource, int, number, int, alt);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (number < 0 || number >= 32) FAIL(INVALID_ARGUMENT);
  if (alt < 0 || alt > 0xff) FAIL(INVALID_ARGUMENT);
  if (resource->is_claimed(number)) FAIL(ALREADY_IN_USE);
  esp_err_t err = resource->claim_interface(number, alt);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(release_interface) {
  ARGS(UsbHostResource, resource, int, number);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (number < 0 || number >= 32) FAIL(INVALID_ARGUMENT);
  esp_err_t err = resource->release_interface(number);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

// For IN requests (bit 7 of request_type set) 'length' bytes are requested
// and 'data' is ignored. For OUT requests 'data' is sent. Returns true, or
// null if an earlier control transfer is still pending (it can't be
// canceled); the caller waits for kControlDoneState and calls again.
PRIMITIVE(control_submit) {
  ARGS(UsbHostResource, resource, int, request_type, int, request, int, value, int, index, Blob, data, int, length, int, max_packet_size0);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  Transfer* t = resource->control();
  if (resource->is_pending(t)) return process->null_object();
  if (request_type < 0 || request_type > 0xff) FAIL(INVALID_ARGUMENT);
  if (request < 0 || request > 0xff) FAIL(INVALID_ARGUMENT);
  if (value < 0 || value > 0xffff) FAIL(INVALID_ARGUMENT);
  if (index < 0 || index > 0xffff) FAIL(INVALID_ARGUMENT);
  bool is_in = (request_type & 0x80) != 0;
  int data_length = is_in ? length : data.length();
  if (data_length < 0 || data_length > kControlDataSize) FAIL(OUT_OF_RANGE);
  if (max_packet_size0 <= 0) FAIL(INVALID_ARGUMENT);

  usb_transfer_t* transfer = t->transfer;
  auto setup = reinterpret_cast<usb_setup_packet_t*>(transfer->data_buffer);
  setup->bmRequestType = request_type;
  setup->bRequest = request;
  setup->wValue = value;
  setup->wIndex = index;
  setup->wLength = data_length;
  int num_bytes = kSetupSize + (is_in ? usb_round_up_to_mps(data_length, max_packet_size0) : data_length);
  if (num_bytes > static_cast<int>(transfer->data_buffer_size)) FAIL(OUT_OF_RANGE);
  if (!is_in) memcpy(transfer->data_buffer + kSetupSize, data.address(), data_length);
  t->is_in = is_in;
  esp_err_t err = resource->submit(t, 0, num_bytes);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->true_object();
}

// The *_finish primitives return null while the transfer is pending, so a
// done event that belongs to an earlier transfer is harmless: the caller
// waits again.

// Returns the received bytes for IN requests, the number of bytes sent
// for OUT requests.
PRIMITIVE(control_finish) {
  ARGS(UsbHostResource, resource);
  Transfer* t = resource->control();
  if (resource->is_pending(t)) return process->null_object();
  usb_transfer_t* transfer = t->transfer;
  if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) return transfer_error(process, transfer->status);
  int actual = transfer->actual_num_bytes - kSetupSize;
  if (actual < 0) actual = 0;
  if (!t->is_in) return Smi::from(actual);
  ByteArray* result = process->allocate_byte_array(actual);
  if (result == null) FAIL(ALLOCATION_FAILED);
  memcpy(ByteArray::Bytes(result).address(), transfer->data_buffer + kSetupSize, actual);
  return result;
}

// Returns the number of bytes accepted for this transfer (at most the
// size of the native buffer).
PRIMITIVE(out_submit) {
  ARGS(UsbHostResource, resource, int, endpoint, Blob, data);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (endpoint <= 0 || endpoint > 0x0f) FAIL(INVALID_ARGUMENT);
  Transfer* t = resource->out();
  if (resource->is_pending(t)) FAIL(INVALID_STATE);
  usb_transfer_t* transfer = t->transfer;
  int length = Utils::min(data.length(), static_cast<int>(transfer->data_buffer_size));
  memcpy(transfer->data_buffer, data.address(), length);
  esp_err_t err = resource->submit(t, endpoint, length);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Smi::from(length);
}

PRIMITIVE(out_finish) {
  ARGS(UsbHostResource, resource);
  Transfer* t = resource->out();
  if (resource->is_pending(t)) return process->null_object();
  usb_transfer_t* transfer = t->transfer;
  if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) {
    resource->clear_halt(t);
    return transfer_error(process, transfer->status);
  }
  return Smi::from(transfer->actual_num_bytes);
}

PRIMITIVE(in_submit) {
  ARGS(UsbHostResource, resource, int, endpoint, int, max, int, max_packet_size);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (endpoint <= 0x80 || endpoint > 0x8f) FAIL(INVALID_ARGUMENT);
  if (resource->is_streaming()) FAIL(ALREADY_IN_USE);
  Transfer* t = resource->in();
  if (resource->is_pending(t)) FAIL(INVALID_STATE);
  if (max <= 0 || max > static_cast<int>(t->transfer->data_buffer_size)) FAIL(OUT_OF_RANGE);
  // The IDF asserts on IN transfers that are not a multiple of the packet
  // size.
  if (max_packet_size <= 0 || max % max_packet_size != 0) FAIL(INVALID_ARGUMENT);
  esp_err_t err = resource->submit(t, endpoint, max);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(in_finish) {
  ARGS(UsbHostResource, resource);
  Transfer* t = resource->in();
  if (resource->is_pending(t)) return process->null_object();
  usb_transfer_t* transfer = t->transfer;
  // The IDF reports no data for canceled transfers, even if packets had
  // arrived.
  if (transfer->status != USB_TRANSFER_STATUS_COMPLETED) {
    resource->clear_halt(t);
    return transfer_error(process, transfer->status);
  }
  int actual = transfer->actual_num_bytes;
  ByteArray* result = process->allocate_byte_array(actual);
  if (result == null) FAIL(ALLOCATION_FAILED);
  memcpy(ByteArray::Bytes(result).address(), transfer->data_buffer, actual);
  return result;
}

// Cancels the pending transfer on a non-control endpoint, if any, and waits
// for it: it completes with USB_TRANSFER_CANCELED.
PRIMITIVE(cancel) {
  ARGS(UsbHostResource, resource, int, endpoint);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (endpoint < 0 || endpoint > 0xff || (endpoint & 0x0f) == 0 || (endpoint & 0x70) != 0) FAIL(INVALID_ARGUMENT);
  // The stream would resubmit; stop it with in_stream_stop.
  if ((endpoint & 0x80) != 0 && resource->is_streaming()) FAIL(INVALID_STATE);
  if (!resource->cancel(endpoint)) return error_string(process, "USB_TRANSFER_STUCK");
  return process->null_object();
}

PRIMITIVE(in_stream_start) {
  ARGS(UsbHostResource, resource, int, endpoint, int, submit_size, int, capacity);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (endpoint <= 0x80 || endpoint > 0x8f) FAIL(INVALID_ARGUMENT);
  Object* error = resource->stream_start(process, endpoint, submit_size, capacity);
  if (error != null) return error;
  return process->null_object();
}

PRIMITIVE(in_stream_read) {
  ARGS(UsbHostResource, resource, int, max);
  if (!resource->is_streaming()) FAIL(INVALID_STATE);
  if (max <= 0) FAIL(INVALID_ARGUMENT);
  return resource->stream_read(process, max);
}

PRIMITIVE(in_stream_stop) {
  ARGS(UsbHostResource, resource);
  if (!resource->stream_stop()) return error_string(process, "USB_TRANSFER_STUCK");
  return process->null_object();
}

} // namespace toit

#endif  // defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_USB_HOST)
