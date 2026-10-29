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
// the hardware can do.
//
// The IDF host stack is a global singleton, and so is its state here
// (UsbHostStack::stack_, with the lib task), and so is the Host: only one
// exists at a time. A Host installs the stack if needed and registers the
// stack's one client (the IDF's name for a user of the stack); it is then
// UsbHostStack::current_host. The next Host, after this one is gone,
// registers its own client.
//
// Each Host has a client task, which lives as long as the Host and pumps
// usb_host_client_handle_events(): that delivers transfer completions and
// the NEW_DEV / DEV_GONE events. In between it carries out the requests
// primitives leave for it: cancel a transfer, close the device, stop. No
// primitive blocks: it asks for something, and Toit waits for the state
// bit (below) that says it has happened.
//
// A resource Toit is done with (Host.close, or the process going away)
// posts no more events, and if its client task is still running it is left
// to it: the task closes the device, exits and deletes the resource. Until
// then it stays current_host and a new Host is told to try again. A
// transfer the device never answers (only control transfers can't be
// canceled) keeps that going until the device is unplugged, which
// completes it.
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
#include <usb/usb_host.h>
#include <esp_log.h>
#include <esp_timer.h>
#include <soc/soc_caps.h>
#if SOC_USB_SERIAL_JTAG_SUPPORTED
#include <hal/usb_serial_jtag_hal.h>
#endif
#include <usb/usb_types_stack.h>

#include "../byte_ring.h"

#include "../objects_inline.h"
#include "../process.h"
#include "../resource.h"

#include "../event_sources/ev_queue_esp32.h"
#include "usb_host_esp32.h"

namespace toit {

static const char* kTag = "usb_host";

// Holds a spinlock. Functions that need it held take a const SpinLocker&,
// which the compiler then checks.
class SpinLocker {
 public:
  explicit SpinLocker(spinlock_t* spinlock) : spinlock_(spinlock) { portENTER_CRITICAL(spinlock_); }
  ~SpinLocker() { portEXIT_CRITICAL(spinlock_); }
 private:
  spinlock_t* spinlock_;
};

class UsbHostResource;

static void lib_task(void* arg);
// Set by UsbHostStack::request_uninstall, read by the lib task without the
// lock.
static std::atomic<bool> stack_stop_requested{false};

// The IDF host stack, a global singleton, and its lib task. The first Host
// installs the stack; the lib task pumps usb_host_lib_handle_events(),
// which runs the root port and the enumeration state machine, and
// uninstalls the stack once the last client is gone.
//
// Uninstalling hands the USB PHY back to USB Serial/JTAG. It only works in
// one order (power the port off, free all devices, pump until ALL_FREE,
// uninstall); if it still fails the stack stays installed with its pump
// running, so the next Host can reuse it (and powers the port on again).
//
// The one instance, stack_, is private and reached through a
// UsbHostStackLocker only, so every access holds the lock.
class UsbHostStack {
 public:
  bool installed = false;
  // Set while the lib task is uninstalling the stack; a new Host must
  // wait.
  bool uninstalling = false;
  // The Host that owns the stack's client: open, or detached and still
  // winding down.
  UsbHostResource* current_host = null;

  // Installs the stack and starts the lib task if needed, and powers the
  // root port.
  esp_err_t ensure_installed();
  // Tells the lib task to uninstall the stack. No client may be registered.
  void request_uninstall();

  // For the lib task and the client tasks. The size the IDF usb_host_lib
  // example uses. Measured peaks on the S3 (2026-10-05, enumeration,
  // transfers, teardown): about 1.2 KB for the lib task and 0.9 KB for the
  // client task; the rest is headroom for IDF error logging, which formats
  // on the calling task's stack.
  static const int kTaskStackSize = 4096;
  // Above the Toit threads (interpreter and event source run at
  // tskIDLE_PRIORITY + 1), so completions are handled and stream chunks
  // resubmitted while Toit is busy, and well below the IDF system tasks
  // (esp_timer, WiFi, lwIP run at 18-23). Anything in that band works; the
  // IDF's usb_host_lib example uses 2 and 3 above a main task at 1.
  static const int kTaskPriority = 5;

 private:
  // Created during static initialization, so it exists before any Host
  // does.
  static UsbHostStack stack_;
  static StaticSemaphore_t mutex_buffer_;
  static SemaphoreHandle_t mutex_;
  friend class UsbHostStackLocker;
};

// How long the lib task pumps for ALL_FREE before it gives up on the
// uninstall.
static const int kUninstallWaitMs = 1000;

UsbHostStack UsbHostStack::stack_;
StaticSemaphore_t UsbHostStack::mutex_buffer_;
SemaphoreHandle_t UsbHostStack::mutex_ = xSemaphoreCreateMutexStatic(&UsbHostStack::mutex_buffer_);

UsbHostStackLocker::UsbHostStackLocker() {
  xSemaphoreTake(UsbHostStack::mutex_, portMAX_DELAY);
}

UsbHostStackLocker::~UsbHostStackLocker() {
  xSemaphoreGive(UsbHostStack::mutex_);
}

UsbHostStack* UsbHostStackLocker::operator->() {
  return &UsbHostStack::stack_;
}

// The stack owns the PHY from usb_host_install to usb_host_uninstall.
// (The uninstall runs on the lib task for up to a second after Host.close
// returns; stdin started in that window stays UART-only, as documented.)
UsbHostPhyLock::UsbHostPhyLock() : host_has_phy_(lock_->installed) {}

// usb_del_phy leaves the shared PHY routed to the OTG controller; hand it
// back to USB Serial/JTAG, the boot-time owner. Call after a successful
// usb_host_uninstall.
static void hand_phy_back() {
#if SOC_USB_SERIAL_JTAG_SUPPORTED && USB_SERIAL_JTAG_LL_EXT_PHY_SUPPORTED
  usb_serial_jtag_hal_phy_set_external(null, false);
#endif
}

// Runs on the lib task once the last client is deregistered. Returns
// whether the stack is uninstalled. If not, it stays installed with the lib
// task pumping, and the next Host reuses it.
static bool uninstall_stack() {
  usb_host_lib_set_root_port_power(false);
  esp_err_t err = usb_host_device_free_all();
  bool all_free = err == ESP_OK;
  int64_t deadline = esp_timer_get_time() + static_cast<int64_t>(kUninstallWaitMs) * 1000;
  err = ESP_ERR_INVALID_STATE;
  while (esp_timer_get_time() < deadline) {
    uint32_t flags = 0;
    usb_host_lib_handle_events(pdMS_TO_TICKS(10), &flags);
    if (flags & USB_HOST_LIB_EVENT_FLAGS_ALL_FREE) all_free = true;
    if (!all_free) continue;
    err = usb_host_uninstall();
    if (err == ESP_OK) break;
  }
  UsbHostStackLocker lock;
  stack_stop_requested = false;
  lock->uninstalling = false;
  if (err != ESP_OK) {
    ESP_LOGE(kTag, "usb_host_uninstall failed (%s), keeping the stack installed", esp_err_to_name(err));
    return false;
  }
  hand_phy_back();
  lock->installed = false;
  return true;
}

static void lib_task(void* arg) {
  while (true) {
    // No timeout needed: request_uninstall wakes us with
    // usb_host_lib_unblock. That gives the binary semaphore
    // usb_host_lib_handle_events blocks on, so an unblock that arrives
    // before we block here stays set until we do; it is not lost.
    esp_err_t err = usb_host_lib_handle_events(portMAX_DELAY, null);
    if (err != ESP_OK && err != ESP_ERR_TIMEOUT) {
      // Can't happen with an installed stack; don't spin on it.
      ESP_LOGE(kTag, "usb_host_lib_handle_events failed: %s", esp_err_to_name(err));
      vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (stack_stop_requested && uninstall_stack()) break;
  }
  vTaskDelete(null);
}

void UsbHostStack::request_uninstall() {
  ASSERT(installed && !uninstalling);
  uninstalling = true;
  stack_stop_requested = true;
  usb_host_lib_unblock();
}

esp_err_t UsbHostStack::ensure_installed() {
  ASSERT(!uninstalling);
  if (!installed) {
    usb_host_config_t host_config = {};
    host_config.skip_phy_setup = false;
    host_config.intr_flags = ESP_INTR_FLAG_LEVEL1;
    // Powered on below, once the lib task exists.
    host_config.root_port_unpowered = true;
    esp_err_t err = usb_host_install(&host_config);
    // INVALID_STATE means either that the IDF already has the stack
    // installed although we don't think so (adopt it rather than failing
    // until reboot), or that the PHY or the controller is in use.
    if (err == ESP_ERR_INVALID_STATE) {
      usb_host_lib_info_t info;
      if (usb_host_lib_info(&info) != ESP_OK) return err;
      ESP_LOGW(kTag, "Adopting an already installed host stack");
    } else if (err != ESP_OK) {
      return err;
    }
    if (xTaskCreatePinnedToCore(lib_task, "usb_lib", kTaskStackSize, null, kTaskPriority, null, tskNO_AFFINITY) != pdPASS) {
      // Nothing is enumerated yet (the port is powered off), so this works
      // right away.
      err = usb_host_uninstall();
      if (err == ESP_OK) {
        hand_phy_back();
      } else {
        ESP_LOGE(kTag, "usb_host_uninstall failed: %s", esp_err_to_name(err));
      }
      return ESP_ERR_NO_MEM;
    }
    installed = true;
  }
  // A failed uninstall leaves the root port powered off, and an adopted
  // stack may have it off too. Does nothing (INVALID_STATE) if it is on.
  // Anything else means the port is stuck (a device the IDF couldn't free
  // keeps it in recovery) and nothing will enumerate: say so.
  esp_err_t err = usb_host_lib_set_root_port_power(true);
  if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(kTag, "Powering the root port failed: %s", esp_err_to_name(err));
  }
  return ESP_OK;
}

// State bits: the client task posts them (UsbHostResource::post) to tell
// the Toit side what happened.
//
// Keep in sync with lib/usb/host.toit.

// A device was enumerated (NEW_DEV): device_open can succeed now.
const uint32 kConnectedState = 1 << 0;
// The open device was unplugged (DEV_GONE, or a transfer ended with
// NO_DEVICE).
const uint32 kGoneState = 1 << 1;
// The control transfer completed: control_finish has its result.
const uint32 kControlDoneState = 1 << 2;
// The IN transfer completed (in_finish has its result), or a stream chunk
// arrived or failed (in_stream_read has it).
const uint32 kInDoneState = 1 << 3;
// The OUT transfer completed: out_finish has its result.
const uint32 kOutDoneState = 1 << 4;
// The device close asked for with device_close is done.
const uint32 kDeviceClosedState = 1 << 5;
// The stop asked for with stop is done: the client task is exiting.
const uint32 kStoppedState = 1 << 6;
// The stream's last transfer completed after a stop. Separate from
// kInDoneState so the stopping task doesn't clear the bit a reader waits on.
const uint32 kInStoppedState = 1 << 7;

// Events are accumulated as bits in the resource; the queue only carries
// wake-ups, and receive_event takes all accumulated bits per wake-up, so a
// post into a full queue loses nothing (the queued wake-up delivers the new
// bits too). One slot would do; the second is slack.
const int kEventQueueSize = 2;
static_assert(kEventQueueSize <= USB_HOST_EVENT_QUEUE_SIZE,
              "Increase USB_HOST_EVENT_QUEUE_SIZE");

const int kSetupSize = sizeof(usb_setup_packet_t);
const int kControlDataSize = CONFIG_USB_HOST_CONTROL_TRANSFER_MAX_SIZE;
const int kTransferBufferSize = 512;

// How often the client task looks at its requests while one is unfinished.
// Also how often a cancel is repeated while the transfer is still pending:
// the IDF ignores a cancel that races with the submit.
const int kServiceIntervalMs = 10;
// How many rounds (of kServiceIntervalMs) the IDF may refuse to release
// an interface before we log it. It refuses while a transfer is in flight
// on one of the interface's endpoints; we wait for ours, so a long refusal
// means a transfer we don't know about.
const int kReleaseRefusalsBeforeWarning = 100;
// How long a stopping Host waits for a control transfer the device never
// answers before it cuts the root port power, which completes the transfer
// with NO_DEVICE. The IDF has no way to cancel a control transfer.
const int kStuckControlMs = 2000;

// Requests for the client task, see UsbHostResource::service.
const uint8 kCancelOut = 1 << 0;
const uint8 kCancelIn = 1 << 1;

// The buffer and state of a streaming IN endpoint: its transfer is
// resubmitted as soon as it completes, into a ring the Toit side drains,
// so no data is lost while Toit is busy. Packet boundaries are lost.
//
// Makes no IDF calls and holds no IDF handles: the owner submits the
// transfers and reports their completions. The client task produces into
// the ring, the Toit thread consumes; the ring itself is single-producer
// single-consumer and needs no lock. Every other field is guarded by the
// owner's spinlock: the methods that need it take the SpinLocker.
// The buffer is only freed by the consumer (or the destructor),
// never by the producer, so a concurrent read is safe; a stopped stream
// keeps its buffer until the owner takes it.
class StreamBuffer {
 public:
  ~StreamBuffer() { free(buffer_); }

  // Whether a buffer is allocated: started and not yet taken. Only the
  // consumer changes this.
  bool is_allocated() const { return buffer_ != null; }
  // Whether the stream is running: allocated and not stopping.
  bool is_running(const SpinLocker&) const { return buffer_ != null && !stopping_; }
  bool is_stopping(const SpinLocker&) const { return stopping_; }
  // The first error, or COMPLETED while the stream is fine.
  usb_transfer_status_t status(const SpinLocker&) const { return status_; }

  // Takes over the buffer of 'capacity' bytes; each transfer asks for
  // 'submit_size' bytes.
  void start(const SpinLocker&, uint8* buffer, word capacity, int submit_size) {
    buffer_ = buffer;
    ring_.init(buffer, capacity);
    submit_size_ = submit_size;
    stopping_ = false;
    status_ = USB_TRANSFER_STATUS_COMPLETED;
  }

  // Whether the next chunk should be submitted: the stream is running and
  // there is room for a whole one. The consumer may call it too, but only
  // while the transfer is idle: the producer then doesn't push, and the
  // lock makes its last push visible.
  bool should_submit(const SpinLocker&) const {
    if (stopping_ || status_ != USB_TRANSFER_STATUS_COMPLETED) return false;
    return ring_.free_space() >= submit_size_;
  }

  // Producer: appends a completed chunk. should_submit made sure it fits.
  void push(const uint8* data, word length) { ring_.push(data, length); }
  // Producer: records the completion (push first). Returns whether to
  // resubmit.
  bool on_done(const SpinLocker& locker, usb_transfer_status_t status) {
    if (status != USB_TRANSFER_STATUS_COMPLETED) status_ = status;
    return should_submit(locker);
  }
  // Producer or consumer: a resubmit failed, which ends the stream.
  void on_submit_failed(const SpinLocker&) { status_ = USB_TRANSFER_STATUS_ERROR; }

  // Consumer.
  word available() const { return ring_.available(); }
  void pop(uint8* to, word length) { ring_.pop(to, length); }
  // Consumer: no more resubmits.
  void stop(const SpinLocker&) { stopping_ = true; }
  // Consumer: gives up the buffer, for the caller to free. The stream must
  // be stopped and its transfer idle.
  uint8* take_buffer(const SpinLocker&) {
    uint8* buffer = buffer_;
    buffer_ = null;
    stopping_ = false;
    return buffer;
  }

 private:
  uint8* buffer_ = null;
  ByteRing ring_;
  int submit_size_ = 0;
  // Set when the stream must not resubmit any more.
  bool stopping_ = false;
  usb_transfer_status_t status_ = USB_TRANSFER_STATUS_COMPLETED;
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
 private:
  // One preallocated IDF transfer and the host's bookkeeping for it.
  // transfer, resource, done_state and is_in are fixed after init. The
  // rest is written by the Toit thread (submit, cancel requests) and the
  // client task (completion), under the resource's spinlock.
  struct Transfer {
    usb_transfer_t* transfer = null;
    UsbHostResource* resource = null;
    uint32 done_state = 0;
    volatile bool pending = false;
    bool is_in = false;
    // Bumped by every submit, so a cancel request can name the transfer it
    // is for and not hit the next one on the same endpoint. A stream's
    // resubmits don't go through submit, so they share one generation.
    uint32 generation = 1;
    // The generation a pending cancel request is for.
    uint32 cancel_generation = 0;
  };

 public:
  TAG(UsbHostResource);

  UsbHostResource(UsbHostResourceGroup* group, QueueHandle_t queue)
      : EventQueueResource(group, queue) {
    spinlock_initialize(&spinlock_);
  }

  ~UsbHostResource() override {
    vQueueDelete(queue());
  }

  // Detaches the resource and deletes it, unless the client task is still
  // running: it then deletes the resource when it exits.
  void delete_or_mark_for_deletion() override;

  // Returns null on success. Sets 'busy' if an earlier Host is still
  // winding down; the caller should try again a little later.
  Object* init(Process* process, bool* busy);

  bool receive_event(word* data) override {
    uint32 wake_up;
    if (!xQueueReceive(queue(), &wake_up, 0)) return false;
    *data = pending_events_.exchange(0);
    return true;
  }

  usb_host_client_handle_t client() const { return client_; }
  // Whether a device is open and usable: not being closed.
  bool has_device() {
    SpinLocker locker(&spinlock_);
    return device_ != null && !device_closing_;
  }
  // Whether a device close is in progress on the client task.
  bool device_closing() {
    SpinLocker locker(&spinlock_);
    return device_closing_;
  }
  // Whether Toit has asked the Host to stop.
  bool is_closing() {
    SpinLocker locker(&spinlock_);
    return closing_;
  }

  // The outcome of a transfer, see finish_control, finish_in, finish_out.
  // While 'pending' the rest is meaningless. On success 'data' points at
  // the received bytes (IN) and 'length' is their count, or the number of
  // bytes sent (OUT, data null).
  struct Completion {
    bool pending;
    usb_transfer_status_t status;
    const uint8* data;
    int length;
  };

  // Submits a control transfer. ESP_ERR_NOT_FINISHED if one is still in
  // flight, ESP_ERR_INVALID_SIZE if the data doesn't fit the buffer. For an
  // IN request (request_type bit 7) 'length' is the number of bytes to ask
  // for; for OUT it is the number of bytes at 'data'.
  esp_err_t submit_control(uint8 request_type, uint8 request, uint16 value, uint16 index,
                           const uint8* data, int length, int max_packet_size0);
  // Submits as much of the data as fits the buffer and stores how much in
  // 'accepted'. ESP_ERR_NOT_FINISHED if a transfer is still in flight.
  esp_err_t submit_out(uint8 endpoint, const uint8* data, int length, int* accepted);
  // Submits an IN transfer for 'length' bytes (a multiple of the packet
  // size; the IDF asserts otherwise). ESP_ERR_NOT_FINISHED if one is still
  // in flight, ESP_ERR_INVALID_SIZE if it doesn't fit the buffer. Frees a
  // stopped stream's buffer.
  esp_err_t submit_in(uint8 endpoint, int length);
  // The outcome of the last transfer of each kind. After a failure the
  // endpoint is ready for the next transfer (see clear_halt). For control
  // transfers the setup packet is not counted.
  Completion finish_control();
  Completion finish_in();
  Completion finish_out();

  // Opens the device that was enumerated, if any: ESP_ERR_NOT_FOUND if
  // none (or it has been unplugged and freed since), ESP_ERR_INVALID_STATE
  // if it is gone but not yet freed, or the Host is stopping.
  esp_err_t open_connected_device();
  // The open device's descriptors; the IDF owns them.
  esp_err_t device_descriptors(const usb_device_desc_t** device_desc,
                               const usb_config_desc_t** config_desc,
                               usb_device_info_t* info);
  // Asks the client task to close the device: it cancels the IN and OUT
  // transfers, waits until all transfers have completed, releases the
  // interfaces, closes the device and posts kDeviceClosedState. Until then
  // has_device() is false. Returns true if there is no device to close.
  bool request_device_close();
  // Asks the client task to cancel the transfer in flight on the endpoint,
  // if any. It completes with CANCELED like any other transfer: wait for
  // its done state and finish it as usual.
  void request_cancel(uint8 endpoint);
  // Asks the client task to close the device and exit; it posts
  // kStoppedState just before it exits.
  void request_stop();
  // Stops posting events, for good. Call before unregistering: the
  // resource's queue must stay empty while it is removed from the queue
  // set.
  void mute() { muted_ = true; }
  // Frees the buffer of a stopped stream, if any. in_ must be idle.
  void discard_stopped_stream();

  bool is_claimed(int number) const { return (claimed_interfaces_ & (1u << number)) != 0; }
  esp_err_t claim_interface(int number, int alt);
  esp_err_t release_interface(int number);

  // Streaming IN, see StreamBuffer: in_ is its transfer, resubmitted by
  // the client task.
  bool is_streaming() {
    SpinLocker locker(&spinlock_);
    return stream_.is_running(locker);
  }
  // Starts streaming into a buffer of 'capacity' bytes; each transfer asks
  // for 'submit_size' bytes (a multiple of the packet size, at most
  // kTransferBufferSize, at most 'capacity'). ESP_ERR_INVALID_STATE if an IN
  // transfer or a stream is in flight, ESP_ERR_NO_MEM if the buffer can't
  // be allocated.
  esp_err_t stream_start(uint8 endpoint, int submit_size, int capacity);
  // What the stream has: the bytes available, and its status. A status
  // other than COMPLETED means the stream is over once the bytes are read;
  // the endpoint is then ready for the next transfer.
  struct StreamStatus {
    usb_transfer_status_t status;
    word available;
  };
  StreamStatus stream_status();
  // Takes 'length' bytes (at most stream_status().available) and lets the
  // stream go on if it was waiting for room.
  void stream_pop(uint8* to, word length);
  // Stops the stream: asks the client task to cancel its transfer. Returns
  // true once the transfer is idle and the buffer is freed, false while the
  // transfer is still in flight (call again after kInStoppedState).
  bool stream_stop();

  // Called from the client task.
  // Whether a request is unfinished, so the client task should come back
  // to service() soon.
  bool has_requests();
  // Carries out the requests. Returns true when the client task should
  // exit.
  bool service();
  // The client task's last call: deletes the resource if Toit is done with
  // it (see delete_or_mark_for_deletion).
  void client_task_exited();

 private:
  // IDF callbacks, on the client task.
  static void client_event_callback(const usb_host_client_event_msg_t* msg, void* arg) {
    unvoid_cast<UsbHostResource*>(arg)->on_client_event(msg);
  }
  static void transfer_callback(usb_transfer_t* transfer) {
    auto t = unvoid_cast<Transfer*>(transfer->context);
    t->resource->on_transfer_done(t);
  }
  void on_client_event(const usb_host_client_event_msg_t* msg);
  void on_transfer_done(Transfer* t);
  void on_stream_done();

  bool is_pending(Transfer* t) {
    SpinLocker locker(&spinlock_);
    return t->pending;
  }
  // Fills in and submits the transfer, which is pending until its callback
  // runs. Endpoint 0 is the control endpoint.
  esp_err_t submit(Transfer* t, uint8 endpoint, int num_bytes);
  // The outcome of a transfer that is no longer pending. Clears the halt
  // after a failure, so the endpoint can be used again.
  Completion finish(Transfer* t);
  // After a transfer failed with STALL, ERROR or OVERFLOW the IDF leaves
  // the endpoint halted and refuses further submits. Clears it, so the
  // endpoint can be used again (the device side of a stall is cleared by
  // the client with CLEAR_FEATURE). Call once the transfer is no longer
  // pending.
  void clear_halt(Transfer* t);
  // Takes the address of a device that was enumerated since the last
  // call. Returns 0 if none.
  uint8 take_new_device_address();
  // Frees the stream buffer. The stream must be stopped and in_ idle.
  void stream_free();
  // Halts, flushes and clears the endpoint, which completes its pending
  // transfer with CANCELED.
  void cancel_now(uint8 endpoint);
  // Whether the pending cancel request for the transfer still applies:
  // the transfer is in flight and is the one the request was for.
  bool cancel_applies(Transfer* t);
  // Submits in_ for the next stream chunk; the caller has set it pending.
  // A failure ends the stream with an error.
  void stream_resubmit();
  // Releases the interfaces and closes the device. Returns false if the
  // IDF isn't ready to release an interface yet; try again later.
  bool finish_device_close();
  // Frees the IDF objects. The client task must have exited.
  void release(UsbHostStackLocker& lock);

  void post(uint32 events) {
    if (muted_) return;
    pending_events_.fetch_or(events);
    uint32 wake_up = 0;
    xQueueSend(queue(), &wake_up, 0);
  }

  // How far init got, so teardown undoes exactly that. These three are
  // read and written under a UsbHostStackLocker.
  bool client_registered_ = false;
  bool client_task_running_ = false;
  // Set once nothing but the client task refers to the resource any more:
  // the client task deletes it when it exits.
  bool detached_ = false;
  std::atomic<bool> muted_{false};
  // Guards the requests, new_device_address_, the transfers' pending
  // flags and the stream's state, which the client task writes. Not the
  // stream's ring.
  spinlock_t spinlock_;
  // State bits posted by the client task, not yet picked up by
  // receive_event.
  std::atomic<uint32> pending_events_{0};
  usb_host_client_handle_t client_ = null;
  // The open device, or null. Opened by a primitive; closed by the client
  // task, after a primitive asked for it.
  usb_device_handle_t device_ = null;
  // The requests for the client task: close the device, stop the Host,
  // cancel transfers.
  bool device_closing_ = false;
  bool closing_ = false;
  uint8 cancel_requests_ = 0;
  // Rounds in which the IDF refused to release an interface.
  int release_refusals_ = 0;
  // When the stop was requested (esp_timer time), and whether the root
  // port power has been cut to complete a stuck control transfer.
  int64_t closing_since_ = 0;
  bool port_power_cut_ = false;
  // Set by the NEW_DEV event, taken by take_new_device_address.
  uint8 new_device_address_ = 0;
  // Bit i set: interface i is claimed and must be released on close.
  uint32 claimed_interfaces_ = 0;
  // One preallocated transfer per kind, so at most one of each is in
  // flight.
  Transfer control_;
  Transfer in_;
  Transfer out_;
  // A stopped stream keeps its buffer until stream_stop finishes or in_ is
  // used again (discard_stopped_stream).
  StreamBuffer stream_;
};

static void client_task(void* arg) {
  auto resource = unvoid_cast<UsbHostResource*>(arg);
  while (true) {
    // A new request wakes us with usb_host_client_unblock.
    TickType_t timeout = resource->has_requests() ? pdMS_TO_TICKS(kServiceIntervalMs) : portMAX_DELAY;
    usb_host_client_handle_events(resource->client(), timeout);
    if (resource->service()) break;
  }
  resource->client_task_exited();
  vTaskDelete(null);
}

void UsbHostResource::on_client_event(const usb_host_client_event_msg_t* msg) {
  switch (msg->event) {
    case USB_HOST_CLIENT_EVENT_NEW_DEV: {
      {
        SpinLocker locker(&spinlock_);
        new_device_address_ = msg->new_dev.address;
      }
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
  if (t == &in_ && stream_.is_allocated()) {
    on_stream_done();
    return;
  }
  {
    SpinLocker locker(&spinlock_);
    t->pending = false;
  }
  uint32 events = t->done_state;
  // The transfer can report the unplug before the DEV_GONE event arrives.
  if (t->transfer->status == USB_TRANSFER_STATUS_NO_DEVICE) events |= kGoneState;
  post(events);
}

bool UsbHostResource::has_requests() {
  SpinLocker locker(&spinlock_);
  return device_closing_ || closing_ || cancel_requests_ != 0;
}

bool UsbHostResource::service() {
  bool closing, device_closing;
  uint8 cancels;
  {
    SpinLocker locker(&spinlock_);
    closing = closing_;
    device_closing = device_closing_;
    cancels = cancel_requests_;
  }

  if (device_closing) {
    // Cancel again on every round: a stream transfer may have been
    // resubmitted after the last cancel. Control transfers can't be
    // canceled; they complete when the device answers or goes away.
    bool idle = !is_pending(&control_);
    Transfer* transfers[] = { &in_, &out_ };
    for (auto t : transfers) {
      if (!is_pending(t)) continue;
      idle = false;
      // Every transfer gets its callback (completed, canceled or
      // NO_DEVICE) as long as we keep pumping, which we do until idle.
      cancel_now(t->transfer->bEndpointAddress);
    }
    if (idle && finish_device_close()) {
      {
        SpinLocker locker(&spinlock_);
        device_ = null;
        device_closing_ = false;
        cancel_requests_ = 0;
      }
      post(kDeviceClosedState);
    }
  } else if (cancels != 0) {
    struct { uint8 bit; Transfer* t; } requests[] = {
      { kCancelOut, &out_ },
      { kCancelIn, &in_ },
    };
    for (auto& request : requests) {
      if ((cancels & request.bit) == 0) continue;
      if (cancel_applies(request.t)) {
        cancel_now(request.t->transfer->bEndpointAddress);
      } else {
        SpinLocker locker(&spinlock_);
        cancel_requests_ &= ~request.bit;
      }
    }
  }

  if (closing) {
    bool done;
    {
      SpinLocker locker(&spinlock_);
      done = device_ == null;
    }
    if (done) {
      post(kStoppedState);
      return true;
    }
    // Only a control transfer can keep the close from finishing (the
    // others were canceled above). Make the device go away instead.
    if (!port_power_cut_ && is_pending(&control_) &&
        esp_timer_get_time() - closing_since_ > static_cast<int64_t>(kStuckControlMs) * 1000) {
      port_power_cut_ = true;
      ESP_LOGW(kTag, "Control transfer stuck, powering off the root port");
      usb_host_lib_set_root_port_power(false);
    }
  }
  return false;
}

bool UsbHostResource::cancel_applies(Transfer* t) {
  SpinLocker locker(&spinlock_);
  return t->pending && t->cancel_generation == t->generation;
}

void UsbHostResource::client_task_exited() {
  UsbHostStackLocker lock;
  client_task_running_ = false;
  if (!detached_) return;
  release(lock);
  delete this;
}

uint8 UsbHostResource::take_new_device_address() {
  uint8 address;
  {
    SpinLocker locker(&spinlock_);
    address = new_device_address_;
    new_device_address_ = 0;
  }
  if (address != 0) return address;
  // The device may have been enumerated before we registered.
  uint8 addresses[1];
  int count = 0;
  usb_host_device_addr_list_fill(1, addresses, &count);
  return count > 0 ? addresses[0] : 0;
}

esp_err_t UsbHostResource::open_connected_device() {
  ASSERT(!has_device());
  if (is_closing()) return ESP_ERR_INVALID_STATE;
  uint8 address = take_new_device_address();
  if (address == 0) return ESP_ERR_NOT_FOUND;
  usb_device_handle_t device = null;
  esp_err_t err = usb_host_device_open(client_, address, &device);
  if (err != ESP_OK) return err;
  bool stopped;
  {
    SpinLocker locker(&spinlock_);
    device_ = device;
    // A stop that came in meanwhile found no device to close. Hand it this
    // one: the client task closes it before it exits.
    stopped = closing_;
    if (stopped) {
      device_closing_ = true;
      stream_.stop(locker);
    }
  }
  if (stopped) {
    usb_host_client_unblock(client_);
    return ESP_ERR_INVALID_STATE;
  }
  return ESP_OK;
}

esp_err_t UsbHostResource::device_descriptors(const usb_device_desc_t** device_desc,
                                              const usb_config_desc_t** config_desc,
                                              usb_device_info_t* info) {
  esp_err_t err = usb_host_get_device_descriptor(device_, device_desc);
  if (err == ESP_OK) err = usb_host_get_active_config_descriptor(device_, config_desc);
  if (err == ESP_OK) err = usb_host_device_info(device_, info);
  return err;
}

bool UsbHostResource::request_device_close() {
  bool closed, request;
  {
    SpinLocker locker(&spinlock_);
    closed = device_ == null && !device_closing_;
    request = !closed && !device_closing_;
    if (request) {
      device_closing_ = true;
      stream_.stop(locker);
    }
  }
  if (request) usb_host_client_unblock(client_);
  return closed;
}

void UsbHostResource::request_cancel(uint8 endpoint) {
  bool is_in = (endpoint & 0x80) != 0;
  Transfer* t = is_in ? &in_ : &out_;
  bool request;
  {
    SpinLocker locker(&spinlock_);
    request = t->pending && t->transfer->bEndpointAddress == endpoint;
    if (request) {
      cancel_requests_ |= is_in ? kCancelIn : kCancelOut;
      t->cancel_generation = t->generation;
    }
  }
  if (request) usb_host_client_unblock(client_);
}

void UsbHostResource::request_stop() {
  {
    SpinLocker locker(&spinlock_);
    closing_ = true;
    closing_since_ = esp_timer_get_time();
    if (device_ != null) device_closing_ = true;
    stream_.stop(locker);
  }
  usb_host_client_unblock(client_);
}

void UsbHostResource::cancel_now(uint8 endpoint) {
  // Halt and flush complete the pending transfer with CANCELED; clear
  // makes the endpoint usable again. Fails harmlessly on a device that is
  // gone: its transfers complete with NO_DEVICE anyway.
  esp_err_t err = usb_host_endpoint_halt(device_, endpoint);
  if (err == ESP_OK) err = usb_host_endpoint_flush(device_, endpoint);
  if (err == ESP_OK) err = usb_host_endpoint_clear(device_, endpoint);
  if (err != ESP_OK) ESP_LOGD(kTag, "Cancel on endpoint 0x%02x failed: %s", endpoint, esp_err_to_name(err));
}

esp_err_t UsbHostResource::submit(Transfer* t, uint8 endpoint, int num_bytes) {
  usb_transfer_t* transfer = t->transfer;
  transfer->num_bytes = num_bytes;
  transfer->bEndpointAddress = endpoint;
  transfer->device_handle = device_;
  transfer->flags = 0;
  {
    SpinLocker locker(&spinlock_);
    t->pending = true;
    t->generation++;
  }
  esp_err_t err = endpoint == 0
      ? usb_host_transfer_submit_control(client_, transfer)
      : usb_host_transfer_submit(transfer);
  if (err != ESP_OK) {
    SpinLocker locker(&spinlock_);
    t->pending = false;
  }
  return err;
}

esp_err_t UsbHostResource::submit_control(uint8 request_type, uint8 request, uint16 value, uint16 index,
                                          const uint8* data, int length, int max_packet_size0) {
  Transfer* t = &control_;
  if (is_pending(t)) return ESP_ERR_NOT_FINISHED;
  bool is_in = (request_type & 0x80) != 0;
  usb_transfer_t* transfer = t->transfer;
  int num_bytes = kSetupSize + (is_in ? usb_round_up_to_mps(length, max_packet_size0) : length);
  if (length < 0 || num_bytes > static_cast<int>(transfer->data_buffer_size)) return ESP_ERR_INVALID_SIZE;
  auto setup = reinterpret_cast<usb_setup_packet_t*>(transfer->data_buffer);
  setup->bmRequestType = request_type;
  setup->bRequest = request;
  setup->wValue = value;
  setup->wIndex = index;
  setup->wLength = length;
  if (!is_in) memcpy(transfer->data_buffer + kSetupSize, data, length);
  t->is_in = is_in;
  return submit(t, 0, num_bytes);
}

esp_err_t UsbHostResource::submit_out(uint8 endpoint, const uint8* data, int length, int* accepted) {
  Transfer* t = &out_;
  if (is_pending(t)) return ESP_ERR_NOT_FINISHED;
  usb_transfer_t* transfer = t->transfer;
  *accepted = Utils::min(length, static_cast<int>(transfer->data_buffer_size));
  memcpy(transfer->data_buffer, data, *accepted);
  return submit(t, endpoint, *accepted);
}

esp_err_t UsbHostResource::submit_in(uint8 endpoint, int length) {
  Transfer* t = &in_;
  if (is_pending(t)) return ESP_ERR_NOT_FINISHED;
  if (length <= 0 || length > static_cast<int>(t->transfer->data_buffer_size)) return ESP_ERR_INVALID_SIZE;
  discard_stopped_stream();
  return submit(t, endpoint, length);
}

UsbHostResource::Completion UsbHostResource::finish(Transfer* t) {
  Completion result = { false, USB_TRANSFER_STATUS_COMPLETED, null, 0 };
  if (is_pending(t)) {
    result.pending = true;
    return result;
  }
  usb_transfer_t* transfer = t->transfer;
  result.status = transfer->status;
  if (result.status != USB_TRANSFER_STATUS_COMPLETED) {
    clear_halt(t);
    return result;
  }
  // The IDF reports no data for canceled transfers, even if packets had
  // arrived.
  if (t == &control_) {
    // The setup packet counts as sent.
    result.length = Utils::max(0, static_cast<int>(transfer->actual_num_bytes) - kSetupSize);
    if (t->is_in) result.data = transfer->data_buffer + kSetupSize;
  } else {
    result.length = transfer->actual_num_bytes;
    if (t->is_in) result.data = transfer->data_buffer;
  }
  return result;
}

UsbHostResource::Completion UsbHostResource::finish_control() { return finish(&control_); }
UsbHostResource::Completion UsbHostResource::finish_in() { return finish(&in_); }
UsbHostResource::Completion UsbHostResource::finish_out() { return finish(&out_); }

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

void UsbHostResource::stream_resubmit() {
  if (usb_host_transfer_submit(in_.transfer) == ESP_OK) return;
  SpinLocker locker(&spinlock_);
  in_.pending = false;
  stream_.on_submit_failed(locker);
}

void UsbHostResource::on_stream_done() {
  usb_transfer_t* transfer = in_.transfer;
  uint32 events = kInDoneState;
  if (transfer->status == USB_TRANSFER_STATUS_COMPLETED) {
    stream_.push(transfer->data_buffer, transfer->actual_num_bytes);
  } else if (transfer->status == USB_TRANSFER_STATUS_NO_DEVICE) {
    events |= kGoneState;
  }
  bool submit;
  {
    SpinLocker locker(&spinlock_);
    // A single write of in_.pending, so service never sees the transfer
    // idle while it is about to be resubmitted.
    submit = stream_.on_done(locker, transfer->status);
    in_.pending = submit;
    if (stream_.is_stopping(locker)) events |= kInStoppedState;
  }
  if (submit) stream_resubmit();
  post(events);
}

esp_err_t UsbHostResource::stream_start(uint8 endpoint, int submit_size, int capacity) {
  if (is_pending(&in_) || is_streaming()) return ESP_ERR_INVALID_STATE;
  ASSERT(submit_size > 0 && submit_size <= kTransferBufferSize && capacity >= submit_size);
  discard_stopped_stream();
  auto buffer = unvoid_cast<uint8*>(malloc(capacity));
  if (buffer == null) return ESP_ERR_NO_MEM;
  {
    SpinLocker locker(&spinlock_);
    stream_.start(locker, buffer, capacity, submit_size);
  }
  esp_err_t err = submit(&in_, endpoint, submit_size);
  if (err != ESP_OK) stream_free();
  return err;
}

UsbHostResource::StreamStatus UsbHostResource::stream_status() {
  // Read the status first: data pushed before an error is then visible.
  usb_transfer_status_t status;
  {
    SpinLocker locker(&spinlock_);
    status = stream_.status(locker);
  }
  word available = stream_.available();
  // The stream is over (no resubmit after an error); the endpoint should
  // work for the next stream or transfer.
  if (available == 0 && status != USB_TRANSFER_STATUS_COMPLETED) clear_halt(&in_);
  return { status, available };
}

void UsbHostResource::stream_pop(uint8* to, word length) {
  // Only the consumer removes data, so what stream_status reported is
  // still there.
  stream_.pop(to, length);
  bool submit;
  {
    SpinLocker locker(&spinlock_);
    // The client task stops submitting when the buffer is full; restart it.
    submit = !in_.pending && stream_.should_submit(locker);
    if (submit) in_.pending = true;
  }
  if (submit) stream_resubmit();
}

bool UsbHostResource::stream_stop() {
  if (!stream_.is_allocated()) return true;
  bool pending;
  {
    SpinLocker locker(&spinlock_);
    stream_.stop(locker);
    pending = in_.pending;
    if (pending) {
      cancel_requests_ |= kCancelIn;
      in_.cancel_generation = in_.generation;
    }
  }
  if (pending) {
    usb_host_client_unblock(client_);
    return false;
  }
  stream_free();
  return true;
}

void UsbHostResource::discard_stopped_stream() {
  if (!stream_.is_allocated()) return;
  ASSERT(!is_streaming());
  stream_free();
}

void UsbHostResource::stream_free() {
  ASSERT(!is_pending(&in_));
  uint8* buffer;
  {
    SpinLocker locker(&spinlock_);
    buffer = stream_.take_buffer(locker);
    // A stop's cancel request may outlive the stream's last transfer; the
    // next IN transfer has a new generation anyway, this just saves a round.
    cancel_requests_ &= ~kCancelIn;
  }
  free(buffer);
}

bool UsbHostResource::finish_device_close() {
  for (int i = 0; i < 32; i++) {
    if ((claimed_interfaces_ & (1u << i)) == 0) continue;
    esp_err_t err = usb_host_interface_release(client_, device_, i);
    // The IDF keeps an endpoint busy for a moment after it reported the
    // completion of its transfer. Releasing anyway would leave the device
    // and the client stuck in the IDF for good, so keep trying: an unplug
    // completes whatever is in flight.
    if (err == ESP_ERR_INVALID_STATE) {
      if (++release_refusals_ == kReleaseRefusalsBeforeWarning) {
        ESP_LOGW(kTag, "Interface %d still busy, waiting to release it", i);
      }
      return false;
    }
    if (err != ESP_OK) ESP_LOGE(kTag, "Releasing interface %d failed: %s", i, esp_err_to_name(err));
    claimed_interfaces_ &= ~(1u << i);
  }
  release_refusals_ = 0;
  esp_err_t err = usb_host_device_close(client_, device_);
  // A device that can't be closed is leaked: the stack then can't be
  // uninstalled and stays around for the next Host.
  if (err != ESP_OK) ESP_LOGE(kTag, "usb_host_device_close failed: %s", esp_err_to_name(err));
  return true;
}

esp_err_t UsbHostResource::claim_interface(int number, int alt) {
  esp_err_t err = usb_host_interface_claim(client_, device_, number, alt);
  if (err == ESP_OK) claimed_interfaces_ |= 1u << number;
  return err;
}

esp_err_t UsbHostResource::release_interface(int number) {
  esp_err_t err = usb_host_interface_release(client_, device_, number);
  if (err == ESP_OK) claimed_interfaces_ &= ~(1u << number);
  return err;
}

static Object* error_string(Process* process, const char* name) {
  String* str = process->allocate_string(name);
  if (str == null) FAIL(ALLOCATION_FAILED);
  return Primitive::mark_as_error(str);
}

Object* UsbHostResource::init(Process* process, bool* busy) {
  *busy = false;
  {
    UsbHostStackLocker lock;
    if (lock->current_host != null) {
      if (!lock->current_host->is_closing()) FAIL(ALREADY_IN_USE);
      *busy = true;
      return null;
    }
    if (lock->uninstalling) {
      *busy = true;
      return null;
    }
    esp_err_t err = lock->ensure_installed();
    if (err != ESP_OK) return Primitive::os_error(err, process);
    usb_host_client_config_t client_config = {};
    client_config.is_synchronous = false;
    client_config.max_num_event_msg = 5;
    client_config.async.client_event_callback = client_event_callback;
    client_config.async.callback_arg = this;
    err = usb_host_client_register(&client_config, &client_);
    if (err != ESP_OK) {
      lock->request_uninstall();
      return Primitive::os_error(err, process);
    }
    client_registered_ = true;
    lock->current_host = this;
  }

  // control_'s direction is set per transfer.
  struct { Transfer* t; int size; uint32 state; bool is_in; } specs[] = {
    { &control_, kSetupSize + kControlDataSize, kControlDoneState, false },
    { &in_, kTransferBufferSize, kInDoneState, true },
    { &out_, kTransferBufferSize, kOutDoneState, false },
  };
  for (auto& spec : specs) {
    esp_err_t err = usb_host_transfer_alloc(spec.size, 0, &spec.t->transfer);
    if (err != ESP_OK) return Primitive::os_error(err, process);
    spec.t->resource = this;
    spec.t->done_state = spec.state;
    spec.t->is_in = spec.is_in;
    spec.t->transfer->callback = transfer_callback;
    spec.t->transfer->context = spec.t;
  }

  UsbHostStackLocker lock;
  if (xTaskCreatePinnedToCore(client_task, "usb_client", UsbHostStack::kTaskStackSize, this, UsbHostStack::kTaskPriority, null, tskNO_AFFINITY) != pdPASS) {
    FAIL(MALLOC_FAILED);
  }
  client_task_running_ = true;
  return null;
}

void UsbHostResource::release(UsbHostStackLocker& lock) {
  ASSERT(!client_task_running_);
  Transfer* transfers[] = { &control_, &in_, &out_ };
  for (auto t : transfers) {
    if (t->transfer == null) continue;
    // Can't happen: the client task only exits once the device is closed,
    // which completes all transfers. Leaking beats a use after free.
    if (is_pending(t)) {
      ESP_LOGE(kTag, "Transfer on endpoint 0x%02x still pending, leaked", t->transfer->bEndpointAddress);
      continue;
    }
    usb_host_transfer_free(t->transfer);
  }
  if (client_registered_) {
    esp_err_t err = usb_host_client_deregister(client_);
    // A client that can't be deregistered keeps the stack installed: the
    // uninstall fails and leaves it running for the next Host.
    if (err != ESP_OK) ESP_LOGE(kTag, "usb_host_client_deregister failed: %s", esp_err_to_name(err));
  }
  if (lock->current_host == this) {
    lock->current_host = null;
    if (lock->installed && !lock->uninstalling) lock->request_uninstall();
  }
}

void UsbHostResource::delete_or_mark_for_deletion() {
  mute();
  {
    UsbHostStackLocker lock;
    if (client_task_running_) {
      // The client task closes the device, exits and then does the
      // release and delete below. The notifier can't wait for that: it
      // lives on the owning process's heap, which may be going away.
      request_stop();
      detached_ = true;
      resource_group()->event_source()->delete_resource_monitor(this);
      return;
    }
    release(lock);
  }
  delete this;
}

void UsbHostResourceGroup::tear_down() {
  // Unregistering drains the event queue, which must not keep refilling.
  for (auto r : resources()) static_cast<UsbHostResource*>(r)->mute();
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
// The result of a *_finish primitive: null while the transfer is pending,
// an error once it failed, the received bytes for IN or the number of bytes
// sent for OUT.
static Object* completion_result(Process* process, const UsbHostResource::Completion& completion) {
  if (completion.pending) return process->null_object();
  if (completion.status != USB_TRANSFER_STATUS_COMPLETED) return transfer_error(process, completion.status);
  if (completion.data == null) return Smi::from(completion.length);
  ByteArray* result = process->allocate_byte_array(completion.length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  memcpy(ByteArray::Bytes(result).address(), completion.data, completion.length);
  return result;
}

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

// Returns null while an earlier Host is still winding down; try again a
// little later.
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

  bool busy;
  Object* result = resource->init(process, &busy);
  if (result != null || busy) {
    resource->delete_or_mark_for_deletion();
    return busy ? process->null_object() : result;
  }

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

// Asks the client task to close the device and exit. kStoppedState is
// posted when it has; close is then quick. Closing without waiting is fine
// too: the resource lives on until the client task is done.
PRIMITIVE(stop) {
  ARGS(UsbHostResource, resource);
  resource->request_stop();
  return process->null_object();
}

PRIMITIVE(close) {
  ARGS(UsbHostResource, resource);
  resource->mute();
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

// Opens the connected device, if any. Returns null if there is none, or
// while the previous device is still being closed; or
// [idVendor, idProduct, bcdDevice, bMaxPacketSize0, bDeviceClass,
//  bDeviceSubClass, bDeviceProtocol, config-descriptor, manufacturer,
//  product, serial-number], where the last three are the UTF-16LE payloads
// of the string descriptors, or null.
PRIMITIVE(device_open) {
  ARGS(UsbHostResource, resource);

  Array* result = process->object_heap()->allocate_array(11, process->null_object());
  if (result == null) FAIL(ALLOCATION_FAILED);

  if (resource->is_closing() || resource->device_closing()) return process->null_object();
  if (!resource->has_device()) {
    esp_err_t err = resource->open_connected_device();
    // No device, or it was unplugged again since it was enumerated.
    if (err == ESP_ERR_NOT_FOUND || err == ESP_ERR_INVALID_STATE) return process->null_object();
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  const usb_device_desc_t* device_desc;
  const usb_config_desc_t* config_desc;
  usb_device_info_t info;
  esp_err_t err = resource->device_descriptors(&device_desc, &config_desc, &info);
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

// Returns true once the device is closed, null while the client task is
// closing it; the caller waits for kDeviceClosedState and calls again.
PRIMITIVE(device_close) {
  ARGS(UsbHostResource, resource);
  if (!resource->request_device_close()) return process->null_object();
  // Closing the device stopped any stream; in_ is idle now.
  resource->discard_stopped_stream();
  return process->true_object();
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

// Returns false if the IDF is still busy with a transfer on one of the
// interface's endpoints, for a moment after it reported the completion;
// try again a little later.
PRIMITIVE(release_interface) {
  ARGS(UsbHostResource, resource, int, number);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (number < 0 || number >= 32) FAIL(INVALID_ARGUMENT);
  esp_err_t err = resource->release_interface(number);
  if (err == ESP_ERR_INVALID_STATE) return process->false_object();
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->true_object();
}

// For IN requests (bit 7 of request_type set) 'length' bytes are requested
// and 'data' is ignored. For OUT requests 'data' is sent. Returns true, or
// null if an earlier control transfer is still pending (it can't be
// canceled); the caller waits for kControlDoneState and calls again.
PRIMITIVE(control_submit) {
  ARGS(UsbHostResource, resource, int, request_type, int, request, int, value, int, index, Blob, data, int, length, int, max_packet_size0);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (request_type < 0 || request_type > 0xff) FAIL(INVALID_ARGUMENT);
  if (request < 0 || request > 0xff) FAIL(INVALID_ARGUMENT);
  if (value < 0 || value > 0xffff) FAIL(INVALID_ARGUMENT);
  if (index < 0 || index > 0xffff) FAIL(INVALID_ARGUMENT);
  if (max_packet_size0 <= 0) FAIL(INVALID_ARGUMENT);
  bool is_in = (request_type & 0x80) != 0;
  int data_length = is_in ? length : data.length();
  if (data_length < 0 || data_length > kControlDataSize) FAIL(OUT_OF_RANGE);
  esp_err_t err = resource->submit_control(request_type, request, value, index, data.address(), data_length, max_packet_size0);
  if (err == ESP_ERR_NOT_FINISHED) return process->null_object();
  if (err == ESP_ERR_INVALID_SIZE) FAIL(OUT_OF_RANGE);
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
  return completion_result(process, resource->finish_control());
}

// Returns the number of bytes accepted for this transfer (at most the
// size of the native buffer).
PRIMITIVE(out_submit) {
  ARGS(UsbHostResource, resource, int, endpoint, Blob, data);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (endpoint <= 0 || endpoint > 0x0f) FAIL(INVALID_ARGUMENT);
  int accepted;
  esp_err_t err = resource->submit_out(endpoint, data.address(), data.length(), &accepted);
  if (err == ESP_ERR_NOT_FINISHED) FAIL(INVALID_STATE);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Smi::from(accepted);
}

PRIMITIVE(out_finish) {
  ARGS(UsbHostResource, resource);
  return completion_result(process, resource->finish_out());
}

PRIMITIVE(in_submit) {
  ARGS(UsbHostResource, resource, int, endpoint, int, max, int, max_packet_size);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (endpoint <= 0x80 || endpoint > 0x8f) FAIL(INVALID_ARGUMENT);
  if (resource->is_streaming()) FAIL(ALREADY_IN_USE);
  if (max <= 0 || max > kTransferBufferSize) FAIL(OUT_OF_RANGE);
  if (max_packet_size <= 0 || max % max_packet_size != 0) FAIL(INVALID_ARGUMENT);
  esp_err_t err = resource->submit_in(endpoint, max);
  if (err == ESP_ERR_NOT_FINISHED) FAIL(INVALID_STATE);
  if (err == ESP_ERR_INVALID_SIZE) FAIL(OUT_OF_RANGE);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

PRIMITIVE(in_finish) {
  ARGS(UsbHostResource, resource);
  return completion_result(process, resource->finish_in());
}

// Cancels the pending transfer on a non-control endpoint, if any. It
// completes with USB_TRANSFER_CANCELED: wait for its done state and finish
// it as usual.
PRIMITIVE(cancel) {
  ARGS(UsbHostResource, resource, int, endpoint);
  // A device that is closing or closed has no transfers left to cancel.
  if (!resource->has_device()) return process->null_object();
  if (endpoint < 0 || endpoint > 0xff || (endpoint & 0x0f) == 0 || (endpoint & 0x70) != 0) FAIL(INVALID_ARGUMENT);
  // The stream would resubmit; stop it with in_stream_stop.
  if ((endpoint & 0x80) != 0 && resource->is_streaming()) FAIL(INVALID_STATE);
  resource->request_cancel(endpoint);
  return process->null_object();
}

PRIMITIVE(in_stream_start) {
  ARGS(UsbHostResource, resource, int, endpoint, int, submit_size, int, max_packet_size, int, capacity);
  if (!resource->has_device()) FAIL(INVALID_STATE);
  if (endpoint <= 0x80 || endpoint > 0x8f) FAIL(INVALID_ARGUMENT);
  if (submit_size <= 0 || submit_size > kTransferBufferSize) FAIL(INVALID_ARGUMENT);
  // The IDF asserts (not fails) on an interrupt IN that isn't a multiple
  // of the packet size.
  if (max_packet_size <= 0 || submit_size % max_packet_size != 0) FAIL(INVALID_ARGUMENT);
  if (capacity < submit_size) FAIL(OUT_OF_RANGE);
  esp_err_t err = resource->stream_start(endpoint, submit_size, capacity);
  if (err == ESP_ERR_INVALID_STATE) FAIL(ALREADY_IN_USE);
  if (err == ESP_ERR_NO_MEM) FAIL(MALLOC_FAILED);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->null_object();
}

// Returns the buffered bytes (at most 'max'), null if there are none and
// the stream is running, or throws once the stream has failed and is
// drained.
PRIMITIVE(in_stream_read) {
  ARGS(UsbHostResource, resource, int, max);
  if (!resource->is_streaming()) FAIL(INVALID_STATE);
  if (max <= 0) FAIL(INVALID_ARGUMENT);
  UsbHostResource::StreamStatus status = resource->stream_status();
  if (status.available == 0) {
    if (status.status != USB_TRANSFER_STATUS_COMPLETED) return transfer_error(process, status.status);
    return process->null_object();
  }
  // Only this primitive removes data, so at least 'length' bytes stay
  // available while we allocate.
  word length = Utils::min(status.available, static_cast<word>(max));
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  resource->stream_pop(ByteArray::Bytes(result).address(), length);
  return result;
}

// Returns true once the stream is stopped, null while its transfer is
// still in flight; the caller waits for kInStoppedState and calls again.
PRIMITIVE(in_stream_stop) {
  ARGS(UsbHostResource, resource);
  if (!resource->stream_stop()) return process->null_object();
  return process->true_object();
}

} // namespace toit

#endif  // defined(TOIT_ESP32) && defined(CONFIG_TOIT_ENABLE_USB_HOST)
