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

#include "../top.h"

#ifdef TOIT_RP2350

#include <string.h>

#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/i2c.h"
#include "hardware/irq.h"
#include "hardware/regs/i2c.h"
#include "pico/time.h"

extern "C" {
  #include "FreeRTOS.h"
  #include "task.h"
}

#include "../event_sources/i2c_rp2350.h"
#include "../event_sources/event_rp2350.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

// Shared GPIO ownership is implemented by gpio_rp2350.cc. I2C accepts only
// non-negative numeric GP identifiers and owns both pins until bus teardown.
bool gpio_pool_take(int pin);
void gpio_pool_put(int pin);

static const int kControllerCount = 2;
static const uint32_t kControllerDoneState = 1 << 0;
static const uint32_t kDefaultStretchTimeoutUs = 100000;
static const uint32_t kMaximumFrequency = 1000000;
static const uint32_t kFifoDepth = 16;
static const word kTargetReceiveState = 1 << 0;
static const word kTargetRequestState = 1 << 1;
static const word kTargetOverflowState = 1 << 2;

enum class ControllerResult : int {
  OK = 0,
  NACK = 1,
  TIMEOUT = 2,
  ERROR = 3,
};

enum class FinishOperationStatus {
  OK,
  INVALID_ARGUMENT,
  INVALID_STATE,
  OUT_OF_BOUNDS,
};

class I2cBusResource;
class I2cControllerResource;

class Rp2350I2cResource : public Resource {
 public:
  explicit Rp2350I2cResource(ResourceGroup* group) : Resource(group) {}

  virtual I2cBusResource* as_bus() { return null; }
  virtual I2cControllerResource* as_controller() { return null; }
};

class I2cControllerResource : public Rp2350I2cResource {
 public:
  I2cControllerResource(ResourceGroup* group, int controller)
      : Rp2350I2cResource(group), controller_(controller) {}

  I2cControllerResource* as_controller() override { return this; }
  int controller() const { return controller_; }
  i2c_inst_t* instance() const { return i2c_get_instance(controller_); }
  i2c_hw_t* hardware() const { return i2c_get_hw(instance()); }
  void set_interrupts_enabled(bool enabled) {
    irq_set_enabled(controller_ == 0 ? I2C0_IRQ : I2C1_IRQ, enabled);
  }

  virtual void handle_interrupt_from_isr() = 0;
  virtual void process_pending(const Locker& locker) = 0;
  virtual bool needs_poll() const { return false; }

 private:
  int controller_;
};

class Rp2350I2cEventSource : public Rp2350PeripheralEventSource {
 public:
  static Rp2350I2cEventSource* instance() { return instance_; }

  Rp2350I2cEventSource();
  ~Rp2350I2cEventSource() override;

  static void arm_timeout(int controller);
  static void cancel(int controller);
  static void notify(int controller);
  static void notify_from_isr(int controller);
  void dispatch_resource(const Locker& locker, Resource* resource, word data) {
    dispatch(locker, resource, data);
  }
  bool poll() override;

 protected:
  void on_register_resource(Locker& locker, Resource* resource) override;
  void on_unregister_resource(Locker& locker, Resource* resource) override;

 private:
  static void i2c0_interrupt();
  static void i2c1_interrupt();
  static void interrupt(int controller);

  void dispatch_pending(const Locker& locker);

  static Rp2350I2cEventSource* instance_;
  static I2cControllerResource* volatile active_[kControllerCount];
  static uint32_t pending_[kControllerCount];
  static uint32_t timeout_poll_mask_;

};

static bool controller_in_use[kControllerCount] = {};

static bool reserve_controller(int controller) {
  Locker locker(OS::global_mutex());
  if (controller_in_use[controller]) return false;
  controller_in_use[controller] = true;
  return true;
}

static void release_controller(int controller) {
  Locker locker(OS::global_mutex());
  ASSERT(controller_in_use[controller]);
  controller_in_use[controller] = false;
}

// RP2350 IO_BANK0's FUNCSEL table repeats in groups of four:
//   GP(4n+0) = I2C0 SDA, GP(4n+1) = I2C0 SCL,
//   GP(4n+2) = I2C1 SDA, GP(4n+3) = I2C1 SCL.
// SDA and SCL may use different groups but must route to the same controller.
static int pins_to_controller(int sda, int scl) {
  if (sda < 0 || scl < 0 ||
      sda >= static_cast<int>(NUM_BANK0_GPIOS) ||
      scl >= static_cast<int>(NUM_BANK0_GPIOS)) return -1;
  if ((sda & 1) != 0 || (scl & 1) != 1) return -1;
  int sda_controller = (sda >> 1) & 1;
  int scl_controller = (scl >> 1) & 1;
  return sda_controller == scl_controller ? sda_controller : -1;
}

static bool is_restricted_pin(int pin) {
#ifdef PICO_PSRAM_CS_PIN
  return pin == PICO_PSRAM_CS_PIN;
#else
  USE(pin);
  return false;
#endif
}

static bool frequency_is_supported(uint32_t frequency) {
  if (frequency == 0 || frequency > kMaximumFrequency) return false;
  uint64_t source = clock_get_hz(clk_sys);
  uint64_t period = (source + frequency / 2) / frequency;
  uint64_t low = period * 3 / 5;
  uint64_t high = period - low;
  if (low < 8 || high < 8 || low > 0xffff || high > 0xffff) return false;
  uint64_t hold = frequency < 1000000
      ? ((source * 3) / 10000000) + 1
      : ((source * 3) / 25000000) + 1;
  return hold <= low - 2;
}

class I2cDeviceResource;

class I2cBusResource : public I2cControllerResource {
 public:
  TAG(I2cBusResource);

  I2cBusResource(ResourceGroup* group, int controller, int sda, int scl)
      : I2cControllerResource(group, controller)
      , sda_(sda)
      , scl_(scl) {}

  ~I2cBusResource() override {
    ASSERT(device_count_ == 0);
    abort_operation();
    set_interrupts_enabled(false);
    i2c_deinit(instance());
    gpio_pool_put(sda_);
    gpio_pool_put(scl_);
    release_controller(controller());
  }

  I2cBusResource* as_bus() override { return this; }

  int device_count() const { return device_count_; }
  bool operation_active() const { return operation_active_; }
  bool operation_complete() const { return operation_complete_; }
  bool operation_belongs_to(I2cDeviceResource* device) const {
    return active_device_ == device;
  }
  uint32_t receive_length() const { return rx_length_; }

  void retain_device() { device_count_++; }
  void release_device() {
    ASSERT(device_count_ > 0);
    device_count_--;
  }

  bool start_operation(I2cDeviceResource* device, uint8_t address,
                       uint32_t frequency, uint32_t timeout_us,
                       bool disable_ack_check, uint8_t* tx, uint32_t tx_length,
                       uint8_t* rx, uint32_t rx_length);
  void handle_interrupt_from_isr() override;
  void process_pending(const Locker& locker) override;
  bool needs_poll() const override {
    return operation_active_ && !operation_complete_;
  }
  bool check_timeout();
  void abort_operation();
  void abort_operation_for(I2cDeviceResource* device);
  FinishOperationStatus finish_operation(I2cDeviceResource* device,
                                         uint8_t* destination,
                                         uint32_t destination_length,
                                         ControllerResult* result);

 private:
  void reset_deadline_from_isr() {
    deadline_us_ = time_us_64() + timeout_us_;
  }

  void fill_fifo_from_isr();
  void complete_from_isr(ControllerResult result);
  void reset_hardware();
  void release_buffers();
  void abort_operation_locked();

  int sda_;
  int scl_;
  int device_count_ = 0;
  uint32_t frequency_ = 100000;

  volatile bool operation_active_ = false;
  volatile bool operation_complete_ = false;
  volatile ControllerResult result_ = ControllerResult::ERROR;
  volatile uint64_t deadline_us_ = 0;
  uint32_t timeout_us_ = kDefaultStretchTimeoutUs;
  bool disable_ack_check_ = false;
  I2cDeviceResource* active_device_ = null;
  uint8_t* tx_ = null;
  uint32_t tx_length_ = 0;
  volatile uint32_t tx_queued_ = 0;
  uint8_t* rx_ = null;
  uint32_t rx_length_ = 0;
  volatile uint32_t read_commands_queued_ = 0;
  volatile uint32_t rx_received_ = 0;
};

class I2cDeviceResource : public Rp2350I2cResource {
 public:
  TAG(I2cDeviceResource);

  I2cDeviceResource(ResourceGroup* group, I2cBusResource* bus,
                    uint8_t address, uint32_t frequency, uint32_t timeout_us,
                    bool disable_ack_check)
      : Rp2350I2cResource(group)
      , bus_(bus)
      , address_(address)
      , frequency_(frequency)
      , timeout_us_(timeout_us)
      , disable_ack_check_(disable_ack_check) {
    bus_->retain_device();
  }

  ~I2cDeviceResource() override {
    bus_->abort_operation_for(this);
    bus_->release_device();
  }

  I2cBusResource* bus() const { return bus_; }
  uint8_t address() const { return address_; }
  uint32_t frequency() const { return frequency_; }
  uint32_t timeout_us() const { return timeout_us_; }
  bool disable_ack_check() const { return disable_ack_check_; }

 private:
  I2cBusResource* bus_;
  uint8_t address_;
  uint32_t frequency_;
  uint32_t timeout_us_;
  bool disable_ack_check_;
};

// The hardware RX FIFO is only 16 bytes deep.  Clock stretching prevents it
// from overflowing while the interrupt is delayed, but completed writes still
// need bounded storage until Toit consumes them.  A transaction is provisional
// until STOP or RESTART: an overlong write rewinds the entire transaction.
class TargetReceiveRing {
 public:
  enum Finish { EMPTY, RECEIVED, OVERFLOW };

  bool initialize(uint32_t capacity) {
    if (capacity == 0 || capacity > SIZE_MAX / sizeof(uint32_t)) return false;
    bytes_ = unvoid_cast<uint8_t*>(malloc(capacity));
    lengths_ = unvoid_cast<uint32_t*>(malloc(capacity * sizeof(uint32_t)));
    if (bytes_ == null || lengths_ == null) {
      free(bytes_);
      free(lengths_);
      bytes_ = null;
      lengths_ = null;
      return false;
    }
    capacity_ = capacity;
    return true;
  }

  ~TargetReceiveRing() {
    free(bytes_);
    free(lengths_);
  }

  void append_from_isr(uint8_t value) {
    if (current_overflow_) return;
    if (used_ + current_length_ == capacity_) {
      current_overflow_ = true;
      return;
    }
    bytes_[(tail_ + current_length_) % capacity_] = value;
    current_length_++;
  }

  void force_overflow_from_isr() { current_overflow_ = true; }
  bool has_current_from_isr() const {
    return current_length_ != 0 || current_overflow_;
  }

  Finish finish_from_isr() {
    if (!has_current_from_isr()) return EMPTY;
    if (current_overflow_ || transaction_count_ == capacity_) {
      current_length_ = 0;
      current_overflow_ = false;
      return OVERFLOW;
    }
    lengths_[length_tail_] = current_length_;
    length_tail_ = (length_tail_ + 1) % capacity_;
    transaction_count_++;
    used_ += current_length_;
    tail_ = (tail_ + current_length_) % capacity_;
    current_length_ = 0;
    return RECEIVED;
  }

  uint32_t first_length() const {
    return transaction_count_ == 0 ? 0 : lengths_[length_head_];
  }

  void copy_and_remove(uint8_t* destination) {
    ASSERT(transaction_count_ != 0);
    uint32_t length = lengths_[length_head_];
    for (uint32_t i = 0; i < length; i++) {
      destination[i] = bytes_[(head_ + i) % capacity_];
    }
    head_ = (head_ + length) % capacity_;
    used_ -= length;
    length_head_ = (length_head_ + 1) % capacity_;
    transaction_count_--;
  }

 private:
  uint8_t* bytes_ = null;
  uint32_t* lengths_ = null;
  uint32_t capacity_ = 0;
  uint32_t head_ = 0;
  uint32_t tail_ = 0;
  uint32_t used_ = 0;
  uint32_t length_head_ = 0;
  uint32_t length_tail_ = 0;
  uint32_t transaction_count_ = 0;
  uint32_t current_length_ = 0;
  bool current_overflow_ = false;
};

class TargetTransmitRing {
 public:
  bool initialize(uint32_t capacity) {
    if (capacity == 0) return false;
    bytes_ = unvoid_cast<uint8_t*>(malloc(capacity));
    if (bytes_ == null) return false;
    capacity_ = capacity;
    return true;
  }
  ~TargetTransmitRing() { free(bytes_); }
  uint32_t free_space() const { return capacity_ - used_; }
  bool is_empty() const { return used_ == 0; }
  uint32_t append(const uint8_t* source, uint32_t length) {
    if (length > free_space()) length = free_space();
    for (uint32_t i = 0; i < length; i++) {
      bytes_[tail_] = source[i];
      tail_ = (tail_ + 1) % capacity_;
    }
    used_ += length;
    return length;
  }
  bool peek_from_isr(uint32_t offset, uint8_t* result) const {
    if (offset >= used_) return false;
    *result = bytes_[(head_ + offset) % capacity_];
    return true;
  }
  void remove_from_isr(uint32_t length) {
    ASSERT(length <= used_);
    head_ = (head_ + length) % capacity_;
    used_ -= length;
  }
  void clear_from_isr() { head_ = tail_ = used_ = 0; }

 private:
  uint8_t* bytes_ = null;
  uint32_t capacity_ = 0;
  uint32_t head_ = 0;
  uint32_t tail_ = 0;
  uint32_t used_ = 0;
};

class I2cTargetResourceBase : public I2cControllerResource {
 public:
  I2cTargetResourceBase(ResourceGroup* group, int controller, int sda, int scl)
      : I2cControllerResource(group, controller), sda_(sda), scl_(scl) {}

  ~I2cTargetResourceBase() override { shut_down(); }

 protected:
  void shut_down() {
    if (shut_down_) return;
    set_interrupts_enabled(false);
    hardware()->intr_mask = 0;
    i2c_deinit(instance());
    gpio_pool_put(sda_);
    gpio_pool_put(scl_);
    release_controller(controller());
    shut_down_ = true;
  }

 public:

  void initialize(uint16_t address, bool ten_bit, bool broadcast) {
    i2c_init(instance(), 100000);
    i2c_hw_t* hw = hardware();
    hw->enable = 0;
    uint32_t con = I2C_IC_CON_SPEED_VALUE_FAST << I2C_IC_CON_SPEED_LSB |
        I2C_IC_CON_IC_RESTART_EN_BITS |
        I2C_IC_CON_RX_FIFO_FULL_HLD_CTRL_BITS |
        I2C_IC_CON_TX_EMPTY_CTRL_BITS;
    // A general-call write is accepted through ACK_GENERAL_CALL but is not
    // considered an address match by STOP_DET_IFADDRESSED. Broadcast targets
    // therefore need unfiltered STOP detection to delimit the received write.
    if (!broadcast) con |= I2C_IC_CON_STOP_DET_IFADDRESSED_BITS;
    if (ten_bit) con |= I2C_IC_CON_IC_10BITADDR_SLAVE_BITS;
    hw->con = con;
    hw->sar = address;
    hw->ack_general_call = broadcast ? 1 : 0;
    hw->slv_data_nack_only = 0;
    hw->rx_tl = 0;
    hw->tx_tl = 0;
    hw->dma_cr = 0;
    (void) hw->clr_intr;
    hw->intr_mask = base_interrupt_mask();
    hw->enable = 1;
  }

 protected:
  static uint32_t base_interrupt_mask() {
    return I2C_IC_INTR_MASK_M_RX_FULL_BITS |
        I2C_IC_INTR_MASK_M_RX_OVER_BITS |
        I2C_IC_INTR_MASK_M_RD_REQ_BITS |
        I2C_IC_INTR_MASK_M_RX_DONE_BITS |
        I2C_IC_INTR_MASK_M_TX_ABRT_BITS |
        I2C_IC_INTR_MASK_M_STOP_DET_BITS |
        I2C_IC_INTR_MASK_M_START_DET_BITS |
        I2C_IC_INTR_MASK_M_GEN_CALL_BITS |
        I2C_IC_INTR_MASK_M_RESTART_DET_BITS;
  }
  void notify_from_isr() { Rp2350I2cEventSource::notify_from_isr(controller()); }

 private:
  int sda_;
  int scl_;
  bool shut_down_ = false;
};

class I2cTargetResource : public I2cTargetResourceBase {
 public:
  TAG(I2cTargetResource);

  I2cTargetResource(ResourceGroup* group, int controller, int sda, int scl)
      : I2cTargetResourceBase(group, controller, sda, scl) {}
  ~I2cTargetResource() override {
    shut_down();
    free(default_response_);
  }

  bool initialize_buffers(uint32_t send_size, uint32_t receive_size,
                          const uint8_t* default_response,
                          uint32_t default_response_length) {
    if (!receive_.initialize(receive_size) ||
        !transmit_.initialize(send_size)) return false;
    default_response_ = unvoid_cast<uint8_t*>(malloc(default_response_length));
    if (default_response_ == null) return false;
    memcpy(default_response_, default_response, default_response_length);
    default_response_length_ = default_response_length;
    return true;
  }

  void handle_interrupt_from_isr() override {
    i2c_hw_t* hw = hardware();
    drain_receive_fifo_from_isr();
    uint32_t status = hw->intr_stat;

    if ((status & I2C_IC_INTR_STAT_R_RX_OVER_BITS) != 0) {
      receive_.force_overflow_from_isr();
      (void) hw->clr_rx_over;
    }

    bool boundary = (status & (I2C_IC_INTR_STAT_R_RESTART_DET_BITS |
                               I2C_IC_INTR_STAT_R_STOP_DET_BITS)) != 0;
    if (boundary) finish_receive_from_isr();
    if ((status & I2C_IC_INTR_STAT_R_RESTART_DET_BITS) != 0) {
      (void) hw->clr_restart_det;
    }
    if ((status & I2C_IC_INTR_STAT_R_STOP_DET_BITS) != 0) {
      (void) hw->clr_stop_det;
    }
    if ((status & I2C_IC_INTR_STAT_R_START_DET_BITS) != 0) {
      (void) hw->clr_start_det;
    }
    if ((status & I2C_IC_INTR_STAT_R_GEN_CALL_BITS) != 0) {
      (void) hw->clr_gen_call;
    }
    uint32_t flushed = UINT32_MAX;
    if ((status & I2C_IC_INTR_STAT_R_TX_ABRT_BITS) != 0) {
      flushed =
          (hw->tx_abrt_source & I2C_IC_TX_ABRT_SOURCE_TX_FLUSH_CNT_BITS) >>
          I2C_IC_TX_ABRT_SOURCE_TX_FLUSH_CNT_LSB;
    }
    if ((status & I2C_IC_INTR_STAT_R_RX_DONE_BITS) != 0) {
      (void) hw->clr_rx_done;
      finish_transmit_from_isr(flushed);
    }
    if ((status & I2C_IC_INTR_STAT_R_TX_ABRT_BITS) != 0) {
      (void) hw->clr_tx_abrt;
      finish_transmit_from_isr(flushed);
    }
    if ((status & I2C_IC_INTR_STAT_R_STOP_DET_BITS) != 0) {
      finish_transmit_from_isr();
    }

    // Draining/clearing can expose a co-latched RD_REQ or TX_EMPTY.  Read the
    // live status again rather than relying on the first snapshot.
    status = hw->intr_stat;
    if ((status & I2C_IC_INTR_STAT_R_RD_REQ_BITS) != 0) {
      if (!read_active_) {
        transmit_uses_default_ = !handler_mode_ && transmit_.is_empty();
      }
      read_active_ = true;
      fill_transmit_fifo(true, true);
    } else if (read_active_ &&
               (status & I2C_IC_INTR_STAT_R_TX_EMPTY_BITS) != 0) {
      finish_fifo_chunk_from_isr();
      fill_transmit_fifo(false, true);
    }
  }

  void process_pending(const Locker& locker) override {
    set_interrupts_enabled(false);
    word events = pending_events_;
    pending_events_ = 0;
    set_interrupts_enabled(true);
    if (events != 0) {
      Rp2350I2cEventSource::instance()->dispatch_resource(
          locker, this, events);
    }
  }

  uint32_t next_receive_length() {
    set_interrupts_enabled(false);
    uint32_t result = receive_.first_length();
    set_interrupts_enabled(true);
    return result;
  }

  void take_receive(uint8_t* destination) {
    set_interrupts_enabled(false);
    receive_.copy_and_remove(destination);
    set_interrupts_enabled(true);
  }

  uint32_t write(const uint8_t* source, uint32_t length) {
    set_interrupts_enabled(false);
    if (discard_response_) {
      set_interrupts_enabled(true);
      return length;
    }
    uint32_t result = transmit_.append(source, length);
    if ((hardware()->raw_intr_stat & I2C_IC_RAW_INTR_STAT_RD_REQ_BITS) != 0) {
      fill_transmit_fifo(true, false);
    } else if ((handler_mode_ || write_pending_) && read_active_) {
      fill_transmit_fifo(false, false);
    }
    set_interrupts_enabled(true);
    return result;
  }

  void set_write_pending(bool pending) {
    set_interrupts_enabled(false);
    write_pending_ = pending;
    if (!pending) {
      discard_response_ = false;
      if (!handler_mode_ && read_active_ &&
          (hardware()->status & I2C_IC_STATUS_TFE_BITS) != 0) {
        fill_transmit_fifo(false, false);
      }
    }
    set_interrupts_enabled(true);
  }

  void set_handler_mode(bool enabled) {
    set_interrupts_enabled(false);
    handler_mode_ = enabled;
    if (!enabled) {
      discard_response_ = false;
      if ((hardware()->raw_intr_stat & I2C_IC_RAW_INTR_STAT_RD_REQ_BITS) != 0) {
        fill_transmit_fifo(true, false);
      }
    }
    set_interrupts_enabled(true);
  }

  word take_request_count() {
    set_interrupts_enabled(false);
    word result = request_count_;
    request_count_ = 0;
    set_interrupts_enabled(true);
    return result;
  }
  word dropped_receive_count() const { return dropped_receive_count_; }

 private:
  void signal_from_isr(word event) {
    pending_events_ |= event;
    notify_from_isr();
  }

  void drain_receive_fifo_from_isr() {
    i2c_hw_t* hw = hardware();
    for (uint32_t i = 0;
         i < kFifoDepth && (hw->status & I2C_IC_STATUS_RFNE_BITS) != 0;
         i++) {
      receive_.append_from_isr(static_cast<uint8_t>(hw->data_cmd));
    }
  }

  void finish_receive_from_isr() {
    TargetReceiveRing::Finish result = receive_.finish_from_isr();
    if (result == TargetReceiveRing::RECEIVED) {
      signal_from_isr(kTargetReceiveState);
    } else if (result == TargetReceiveRing::OVERFLOW) {
      if (dropped_receive_count_ != Smi::MAX_SMI_VALUE) dropped_receive_count_++;
      signal_from_isr(kTargetOverflowState);
    }
  }

  void request_response(bool from_isr) {
    if (request_outstanding_) return;
    request_outstanding_ = true;
    if (request_count_ != Smi::MAX_SMI_VALUE) request_count_++;
    pending_events_ |= kTargetRequestState;
    if (from_isr) notify_from_isr();
    else Rp2350I2cEventSource::notify(controller());
  }

  void fill_transmit_fifo(bool rd_request, bool from_isr) {
    i2c_hw_t* hw = hardware();
    bool loaded = false;
    for (uint32_t i = 0;
         i < kFifoDepth && (hw->status & I2C_IC_STATUS_TFNF_BITS) != 0;
         i++) {
      uint8_t value;
      if (!transmit_uses_default_ &&
          transmit_.peek_from_isr(queued_loaded_, &value)) {
        loaded = true;
        queued_loaded_++;
        request_outstanding_ = false;
      } else if (!handler_mode_ && !write_pending_) {
        // Once a transaction reaches its fallback response, bytes queued by
        // another task belong to the next transaction and must not splice in.
        transmit_uses_default_ = true;
        value = default_response_[default_index_++];
        if (default_index_ == default_response_length_) default_index_ = 0;
        loaded = true;
      } else if (write_pending_) {
        // The current blocking write has more bytes to append. Empty-FIFO
        // clock stretching keeps this response intact until its writer is
        // woken by the chunk-completion event above.
        break;
      } else {
        ASSERT(handler_mode_);
        // A response shorter than the FIFO is still one complete handler
        // response.  Ask again only after the controller has consumed it and
        // TX_EMPTY fires, rather than while preloading the same FIFO.
        if (!loaded) request_response(from_isr);
        break;
      }
      hw->data_cmd = value;
      fifo_loaded_++;
    }
    if (rd_request && loaded) {
      (void) hw->clr_rd_req;
      hw->intr_mask |= I2C_IC_INTR_MASK_M_RD_REQ_BITS;
    } else if (rd_request) {
      // RD_REQ remains asserted and keeps SCL low. Mask its level interrupt
      // until a Toit response arrives, otherwise it would retrigger forever
      // and starve the shared dispatcher that must run the handler.
      hw->intr_mask &= ~I2C_IC_INTR_MASK_M_RD_REQ_BITS;
    }
    if (loaded) hw->intr_mask |= I2C_IC_INTR_MASK_M_TX_EMPTY_BITS;
    else hw->intr_mask &= ~I2C_IC_INTR_MASK_M_TX_EMPTY_BITS;
  }

  void finish_fifo_chunk_from_isr() {
    if (queued_loaded_ != 0) {
      transmit_.remove_from_isr(queued_loaded_);
      queued_loaded_ = 0;
      signal_from_isr(kTargetRequestState);
    }
    fifo_loaded_ = 0;
  }

  void finish_transmit_from_isr(uint32_t known_unsent = UINT32_MAX) {
    if (!read_active_) return;
    uint32_t unsent = known_unsent == UINT32_MAX
        ? hardware()->txflr
        : known_unsent;
    if (unsent > fifo_loaded_) unsent = fifo_loaded_;
    uint32_t sent = fifo_loaded_ - unsent;
    uint32_t sent_queued = sent < queued_loaded_ ? sent : queued_loaded_;
    if (sent_queued != 0) {
      transmit_.remove_from_isr(sent_queued);
      signal_from_isr(kTargetRequestState);
    }
    queued_loaded_ = 0;
    fifo_loaded_ = 0;
    read_active_ = false;
    transmit_uses_default_ = false;
    default_index_ = 0;
    request_outstanding_ = false;
    hardware()->intr_mask &= ~I2C_IC_INTR_MASK_M_TX_EMPTY_BITS;
    if (handler_mode_) {
      transmit_.clear_from_isr();
      if (write_pending_) discard_response_ = true;
    }
  }

  TargetReceiveRing receive_;
  TargetTransmitRing transmit_;
  uint8_t* default_response_ = null;
  uint32_t default_response_length_ = 0;
  uint32_t default_index_ = 0;
  uint32_t queued_loaded_ = 0;
  uint32_t fifo_loaded_ = 0;
  volatile word pending_events_ = 0;
  volatile word request_count_ = 0;
  volatile word dropped_receive_count_ = 0;
  volatile bool handler_mode_ = false;
  volatile bool write_pending_ = false;
  volatile bool discard_response_ = false;
  volatile bool read_active_ = false;
  volatile bool transmit_uses_default_ = false;
  volatile bool request_outstanding_ = false;
};

class I2cRegisterTargetResource : public I2cTargetResourceBase {
 public:
  TAG(I2cRegisterTargetResource);

  I2cRegisterTargetResource(ResourceGroup* group, int controller,
                            int sda, int scl, uint8_t* registers,
                            uint32_t register_count, uint32_t address_bytes)
      : I2cTargetResourceBase(group, controller, sda, scl)
      , registers_(registers)
      , register_count_(register_count)
      , address_bytes_(address_bytes) {}
  ~I2cRegisterTargetResource() override {
    shut_down();
    free(scratch_);
    free(registers_);
  }

  bool initialize_buffer(uint32_t size) { return receive_.initialize(size); }
  uint32_t register_count() const { return register_count_; }

  void handle_interrupt_from_isr() override {
    i2c_hw_t* hw = hardware();
    for (uint32_t i = 0;
         i < kFifoDepth && (hw->status & I2C_IC_STATUS_RFNE_BITS) != 0;
         i++) {
      receive_.append_from_isr(static_cast<uint8_t>(hw->data_cmd));
    }
    uint32_t status = hw->intr_stat;
    if ((status & I2C_IC_INTR_STAT_R_RX_OVER_BITS) != 0) {
      receive_.force_overflow_from_isr();
      (void) hw->clr_rx_over;
    }
    if ((status & (I2C_IC_INTR_STAT_R_RESTART_DET_BITS |
                   I2C_IC_INTR_STAT_R_STOP_DET_BITS)) != 0) {
      finish_receive_from_isr();
    }
    if ((status & I2C_IC_INTR_STAT_R_RESTART_DET_BITS) != 0) (void) hw->clr_restart_det;
    if ((status & I2C_IC_INTR_STAT_R_STOP_DET_BITS) != 0) {
      (void) hw->clr_stop_det;
    }
    if ((status & I2C_IC_INTR_STAT_R_START_DET_BITS) != 0) (void) hw->clr_start_det;
    if ((status & I2C_IC_INTR_STAT_R_GEN_CALL_BITS) != 0) (void) hw->clr_gen_call;
    uint32_t flushed = UINT32_MAX;
    if ((status & I2C_IC_INTR_STAT_R_TX_ABRT_BITS) != 0) {
      flushed =
          (hw->tx_abrt_source & I2C_IC_TX_ABRT_SOURCE_TX_FLUSH_CNT_BITS) >>
          I2C_IC_TX_ABRT_SOURCE_TX_FLUSH_CNT_LSB;
    }
    if ((status & I2C_IC_INTR_STAT_R_RX_DONE_BITS) != 0) {
      (void) hw->clr_rx_done;
      finish_transmit_from_isr(flushed);
    }
    if ((status & I2C_IC_INTR_STAT_R_TX_ABRT_BITS) != 0) {
      (void) hw->clr_tx_abrt;
      finish_transmit_from_isr(flushed);
    }
    if ((status & I2C_IC_INTR_STAT_R_STOP_DET_BITS) != 0) {
      finish_transmit_from_isr();
    }
    status = hw->intr_stat;
    if ((status & I2C_IC_INTR_STAT_R_RD_REQ_BITS) != 0) {
      hw->intr_mask &= ~I2C_IC_INTR_MASK_M_RD_REQ_BITS;
      if (!read_waiting_) {
        read_waiting_ = true;
        notify_from_isr();
      }
      // Do not clear RD_REQ: the dispatcher first commits the preceding write.
    } else if (transmit_active_ &&
               (status & I2C_IC_INTR_STAT_R_TX_EMPTY_BITS) != 0) {
      fill_transmit_from_isr();
    }
  }

  void process_pending(const Locker& locker) override {
    USE(locker);
    set_interrupts_enabled(false);
    while (receive_.first_length() != 0) apply_first_write();
    if (read_waiting_) {
      read_waiting_ = false;
      start_transmit();
    }
    set_interrupts_enabled(true);
  }

  int get(uint32_t index) {
    Locker locker(resource_group()->event_source()->mutex());
    set_interrupts_enabled(false);
    int result = registers_[index];
    set_interrupts_enabled(true);
    return result;
  }
  void set(uint32_t index, uint8_t value) {
    Locker locker(resource_group()->event_source()->mutex());
    set_interrupts_enabled(false);
    registers_[index] = value;
    set_interrupts_enabled(true);
  }
  void read(uint32_t index, uint8_t* out, uint32_t length) {
    Locker locker(resource_group()->event_source()->mutex());
    set_interrupts_enabled(false);
    memcpy(out, registers_ + index, length);
    set_interrupts_enabled(true);
  }
  void write(uint32_t index, const uint8_t* in, uint32_t length) {
    Locker locker(resource_group()->event_source()->mutex());
    set_interrupts_enabled(false);
    memcpy(registers_ + index, in, length);
    set_interrupts_enabled(true);
  }
  word dropped_write_count() const { return dropped_write_count_; }

 private:
  void finish_receive_from_isr() {
    TargetReceiveRing::Finish result = receive_.finish_from_isr();
    if (result == TargetReceiveRing::OVERFLOW) {
      if (dropped_write_count_ != Smi::MAX_SMI_VALUE) dropped_write_count_++;
    }
    if (result != TargetReceiveRing::EMPTY) notify_from_isr();
  }

  void apply_first_write() {
    uint32_t length = receive_.first_length();
    if (length == 0) return;
    // The configured receive capacity bounds this reusable native buffer.
    uint8_t* bytes = scratch_;
    receive_.copy_and_remove(bytes);
    if (length < address_bytes_) return;
    uint32_t pointer = 0;
    for (uint32_t i = 0; i < address_bytes_; i++) pointer = (pointer << 8) | bytes[i];
    pointer %= register_count_;
    for (uint32_t i = address_bytes_; i < length; i++) {
      registers_[pointer++] = bytes[i];
      if (pointer == register_count_) pointer = 0;
    }
    register_pointer_ = pointer;
  }

  void start_transmit() {
    // RD_REQ can recur during a read if the controller drains the FIFO before
    // TX_EMPTY is serviced. Resume at the next register instead of replaying
    // the prefix; the public register pointer is committed when the read ends.
    if (!transmit_active_) {
      transmit_start_ = register_pointer_;
      transmit_loaded_ = 0;
      transmit_active_ = true;
    }
    fill_transmit_from_isr();
    (void) hardware()->clr_rd_req;
    hardware()->intr_mask |= I2C_IC_INTR_MASK_M_RD_REQ_BITS |
        I2C_IC_INTR_MASK_M_TX_EMPTY_BITS;
  }

  void fill_transmit_from_isr() {
    i2c_hw_t* hw = hardware();
    for (uint32_t i = 0;
         i < kFifoDepth && (hw->status & I2C_IC_STATUS_TFNF_BITS) != 0;
         i++) {
      uint32_t index = (transmit_start_ + transmit_loaded_) % register_count_;
      hw->data_cmd = registers_[index];
      transmit_loaded_++;
    }
  }

  void finish_transmit_from_isr(uint32_t known_unsent = UINT32_MAX) {
    if (!transmit_active_) return;
    uint32_t unsent = known_unsent == UINT32_MAX
        ? hardware()->txflr
        : known_unsent;
    if (unsent > transmit_loaded_) unsent = transmit_loaded_;
    uint32_t sent = transmit_loaded_ > unsent ? transmit_loaded_ - unsent : 0;
    register_pointer_ = (transmit_start_ + sent) % register_count_;
    transmit_active_ = false;
    hardware()->intr_mask &= ~I2C_IC_INTR_MASK_M_TX_EMPTY_BITS;
  }

 public:
  bool allocate_scratch(uint32_t size) {
    scratch_ = unvoid_cast<uint8_t*>(malloc(size));
    return scratch_ != null;
  }

 private:
  TargetReceiveRing receive_;
  uint8_t* registers_;
  uint8_t* scratch_ = null;
  uint32_t register_count_;
  uint32_t address_bytes_;
  uint32_t register_pointer_ = 0;
  uint32_t transmit_start_ = 0;
  uint32_t transmit_loaded_ = 0;
  volatile word dropped_write_count_ = 0;
  volatile bool read_waiting_ = false;
  volatile bool transmit_active_ = false;
};

class I2cTargetResourceGroup : public ResourceGroup {
 public:
  TAG(I2cTargetResourceGroup);
  I2cTargetResourceGroup(Process* process, EventSource* source)
      : ResourceGroup(process, source) {}
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    return state | data;
  }
};

class I2cResourceGroup : public ResourceGroup {
 public:
  TAG(I2cResourceGroup);

  I2cResourceGroup(Process* process, EventSource* source)
      : ResourceGroup(process, source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    USE(resource);
    USE(data);
    return state | kControllerDoneState;
  }
};

Rp2350I2cEventSource* Rp2350I2cEventSource::instance_ = null;
I2cControllerResource* volatile
    Rp2350I2cEventSource::active_[kControllerCount] = {};
uint32_t Rp2350I2cEventSource::pending_[kControllerCount] = {};
uint32_t Rp2350I2cEventSource::timeout_poll_mask_ = 0;

Rp2350I2cEventSource::Rp2350I2cEventSource()
    : Rp2350PeripheralEventSource("RP2350 I2C") {
  ASSERT(instance_ == null);
  instance_ = this;

  irq_set_exclusive_handler(I2C0_IRQ, i2c0_interrupt);
  irq_set_exclusive_handler(I2C1_IRQ, i2c1_interrupt);
  irq_set_priority(I2C0_IRQ, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_priority(I2C1_IRQ, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_enabled(I2C0_IRQ, false);
  irq_set_enabled(I2C1_IRQ, false);
  Rp2350EventDispatcher::instance()->attach(Rp2350EventDispatcher::I2C, this);
}

Rp2350I2cEventSource::~Rp2350I2cEventSource() {
  irq_set_enabled(I2C0_IRQ, false);
  irq_set_enabled(I2C1_IRQ, false);
  irq_remove_handler(I2C0_IRQ, i2c0_interrupt);
  irq_remove_handler(I2C1_IRQ, i2c1_interrupt);
  instance_ = null;
  Rp2350EventDispatcher::instance()->detach(Rp2350EventDispatcher::I2C, this);
}

void Rp2350I2cEventSource::on_register_resource(
    Locker& locker, Resource* resource) {
  USE(locker);
  auto i2c_resource = static_cast<Rp2350I2cResource*>(resource);
  I2cControllerResource* controller_resource = i2c_resource->as_controller();
  if (controller_resource == null) return;
  int controller = controller_resource->controller();
  ASSERT(active_[controller] == null);
  active_[controller] = controller_resource;
  __atomic_store_n(&pending_[controller], 0, __ATOMIC_RELEASE);
  __atomic_fetch_and(&timeout_poll_mask_, ~(1u << controller),
                     __ATOMIC_RELEASE);
  controller_resource->set_interrupts_enabled(true);
}

void Rp2350I2cEventSource::on_unregister_resource(
    Locker& locker, Resource* resource) {
  USE(locker);
  auto i2c_resource = static_cast<Rp2350I2cResource*>(resource);
  I2cControllerResource* controller_resource = i2c_resource->as_controller();
  if (controller_resource == null) return;
  int controller = controller_resource->controller();
  controller_resource->set_interrupts_enabled(false);
  active_[controller] = null;
  __atomic_store_n(&pending_[controller], 0, __ATOMIC_RELEASE);
  __atomic_fetch_and(&timeout_poll_mask_, ~(1u << controller),
                     __ATOMIC_RELEASE);
}

void Rp2350I2cEventSource::arm_timeout(int controller) {
  Rp2350I2cEventSource* source = instance_;
  if (source == null) return;
  uint32_t previous = __atomic_fetch_or(
      &timeout_poll_mask_, 1u << controller, __ATOMIC_ACQ_REL);
  if ((previous & (1u << controller)) != 0) return;
  Rp2350EventDispatcher::instance()->wake();
}

void Rp2350I2cEventSource::cancel(int controller) {
  __atomic_fetch_and(&timeout_poll_mask_, ~(1u << controller),
                     __ATOMIC_RELEASE);
  __atomic_store_n(&pending_[controller], 0, __ATOMIC_RELEASE);
}

void Rp2350I2cEventSource::notify(int controller) {
  Rp2350I2cEventSource* source = instance_;
  if (source == null) return;
  uint32_t previous = __atomic_exchange_n(
      &pending_[controller], 1, __ATOMIC_ACQ_REL);
  if (previous == 0) Rp2350EventDispatcher::instance()->wake();
}

void Rp2350I2cEventSource::notify_from_isr(int controller) {
  Rp2350I2cEventSource* source = instance_;
  if (source == null) return;
  __atomic_fetch_and(&timeout_poll_mask_, ~(1u << controller),
                     __ATOMIC_RELEASE);
  uint32_t previous = __atomic_exchange_n(
      &pending_[controller], 1, __ATOMIC_ACQ_REL);
  if (previous != 0) return;
  Rp2350EventDispatcher::instance()->wake_from_isr();
}

void Rp2350I2cEventSource::i2c0_interrupt() { interrupt(0); }
void Rp2350I2cEventSource::i2c1_interrupt() { interrupt(1); }

void Rp2350I2cEventSource::interrupt(int controller) {
  I2cControllerResource* resource = active_[controller];
  if (resource != null) resource->handle_interrupt_from_isr();
}

void Rp2350I2cEventSource::dispatch_pending(const Locker& locker) {
  for (int controller = 0; controller < kControllerCount; controller++) {
    I2cControllerResource* resource = active_[controller];
    if (resource == null) continue;
    uint32_t pending = __atomic_exchange_n(
        &pending_[controller], 0, __ATOMIC_ACQ_REL);
    uint32_t poll_mask = __atomic_load_n(
        &timeout_poll_mask_, __ATOMIC_ACQUIRE);
    if (pending != 0 || (poll_mask & (1u << controller)) != 0) {
      resource->process_pending(locker);
    }
  }
}

bool Rp2350I2cEventSource::poll() {
  Locker locker(mutex());
  dispatch_pending(locker);
  for (int controller = 0; controller < kControllerCount; controller++) {
    I2cControllerResource* resource = active_[controller];
    if (resource != null && resource->needs_poll()) return true;
  }
  return false;
}

EventSource* create_rp2350_i2c_event_source() {
  return _new Rp2350I2cEventSource();
}

void I2cBusResource::fill_fifo_from_isr() {
  i2c_hw_t* hw = hardware();
  if ((hw->status & I2C_IC_STATUS_TFNF_BITS) != 0) {
    uint32_t command;
    if (tx_queued_ < tx_length_) {
      command = tx_[tx_queued_];
      tx_queued_++;
      if (tx_queued_ == tx_length_ && rx_length_ == 0) {
        command |= I2C_IC_DATA_CMD_STOP_BITS;
      }
    } else if (read_commands_queued_ < rx_length_ &&
               read_commands_queued_ - rx_received_ < kFifoDepth) {
      command = I2C_IC_DATA_CMD_CMD_BITS;
      if (read_commands_queued_ == 0 && tx_length_ != 0) {
        command |= I2C_IC_DATA_CMD_RESTART_BITS;
      }
      read_commands_queued_++;
      if (read_commands_queued_ == rx_length_) {
        command |= I2C_IC_DATA_CMD_STOP_BITS;
      }
    } else {
      return;
    }
    hw->data_cmd = command;
  }

  if (tx_queued_ == tx_length_ &&
      read_commands_queued_ == rx_length_) {
    hw->intr_mask &= ~I2C_IC_INTR_MASK_M_TX_EMPTY_BITS;
  } else {
    hw->intr_mask |= I2C_IC_INTR_MASK_M_TX_EMPTY_BITS;
  }
}

void I2cBusResource::complete_from_isr(ControllerResult result) {
  if (!operation_active_ || operation_complete_) return;
  hardware()->intr_mask = 0;
  result_ = result;
  operation_complete_ = true;
  Rp2350I2cEventSource::notify_from_isr(controller());
}

void I2cBusResource::handle_interrupt_from_isr() {
  i2c_hw_t* hw = hardware();
  if (!operation_active_ || operation_complete_) {
    hw->intr_mask = 0;
    return;
  }

  uint32_t status = hw->intr_stat;
  if ((status & I2C_IC_INTR_STAT_R_TX_ABRT_BITS) != 0) {
    uint32_t reason = hw->tx_abrt_source;
    (void) hw->clr_tx_abrt;
    (void) hw->clr_stop_det;
    bool nack = (reason &
        (I2C_IC_TX_ABRT_SOURCE_ABRT_7B_ADDR_NOACK_BITS |
         I2C_IC_TX_ABRT_SOURCE_ABRT_TXDATA_NOACK_BITS)) != 0;
    bool ignore_nack = disable_ack_check_ && rx_length_ == 0 && nack;
    complete_from_isr(ignore_nack
        ? ControllerResult::OK
        : nack ? ControllerResult::NACK : ControllerResult::ERROR);
    return;
  }

  bool progressed = false;
  while ((hw->status & I2C_IC_STATUS_RFNE_BITS) != 0) {
    uint8_t byte = static_cast<uint8_t>(hw->data_cmd);
    if (rx_received_ >= rx_length_) {
      complete_from_isr(ControllerResult::ERROR);
      return;
    }
    rx_[rx_received_++] = byte;
    progressed = true;
  }

  if ((status & I2C_IC_INTR_STAT_R_TX_EMPTY_BITS) != 0) progressed = true;
  fill_fifo_from_isr();
  if (progressed) reset_deadline_from_isr();

  if ((status & I2C_IC_INTR_STAT_R_STOP_DET_BITS) != 0) {
    (void) hw->clr_stop_det;
    bool complete = tx_queued_ == tx_length_ &&
        read_commands_queued_ == rx_length_ &&
        rx_received_ == rx_length_;
    complete_from_isr(complete
        ? ControllerResult::OK
        : ControllerResult::ERROR);
  }
}

void I2cBusResource::process_pending(const Locker& locker) {
  if (!operation_complete() && !check_timeout()) return;
  Rp2350I2cEventSource::cancel(controller());
  Rp2350I2cEventSource::instance()->dispatch_resource(
      locker, this, kControllerDoneState);
}

void I2cBusResource::reset_hardware() {
  set_interrupts_enabled(false);
  i2c_deinit(instance());
  i2c_init(instance(), frequency_);
  // Reset restores the hardware's default interrupt mask, including TX_EMPTY.
  // Mask it before re-enabling the NVIC: an aborted transfer has no commands
  // left to queue, so that level interrupt would otherwise starve the thread
  // before it can publish the timeout or release the transfer buffers.
  hardware()->intr_mask = 0;
  (void) hardware()->clr_intr;
  set_interrupts_enabled(true);
}

void I2cBusResource::release_buffers() {
  free(tx_);
  free(rx_);
  tx_ = null;
  rx_ = null;
  tx_length_ = 0;
  rx_length_ = 0;
  tx_queued_ = 0;
  read_commands_queued_ = 0;
  rx_received_ = 0;
  active_device_ = null;
}

bool I2cBusResource::start_operation(
    I2cDeviceResource* device, uint8_t address, uint32_t frequency,
    uint32_t timeout_us, bool disable_ack_check, uint8_t* tx,
    uint32_t tx_length, uint8_t* rx, uint32_t rx_length) {
  Locker locker(resource_group()->event_source()->mutex());
  if (operation_active_) return false;

  frequency_ = frequency;
  timeout_us_ = timeout_us == 0 ? kDefaultStretchTimeoutUs : timeout_us;
  disable_ack_check_ = disable_ack_check;
  active_device_ = device;
  tx_ = tx;
  tx_length_ = tx_length;
  rx_ = rx;
  rx_length_ = rx_length;
  tx_queued_ = 0;
  read_commands_queued_ = 0;
  rx_received_ = 0;
  result_ = ControllerResult::ERROR;
  operation_complete_ = false;
  operation_active_ = true;

  set_interrupts_enabled(false);
  i2c_set_baudrate(instance(), frequency);
  i2c_hw_t* hw = hardware();
  hw->enable = 0;
  hw->tar = address;
  hw->enable = 1;
  (void) hw->clr_intr;
  deadline_us_ = time_us_64() + timeout_us_;
  fill_fifo_from_isr();
  hw->intr_mask |= I2C_IC_INTR_MASK_M_TX_ABRT_BITS |
                   I2C_IC_INTR_MASK_M_STOP_DET_BITS |
                   I2C_IC_INTR_MASK_M_RX_FULL_BITS;
  Rp2350I2cEventSource::arm_timeout(controller());
  set_interrupts_enabled(true);
  return true;
}

bool I2cBusResource::check_timeout() {
  set_interrupts_enabled(false);
  if (!operation_active_ || operation_complete_) {
    set_interrupts_enabled(true);
    return false;
  }
  if (static_cast<int64_t>(time_us_64() - deadline_us_) < 0) {
    set_interrupts_enabled(true);
    return false;
  }
  reset_hardware();
  result_ = ControllerResult::TIMEOUT;
  operation_complete_ = true;
  return true;
}

void I2cBusResource::abort_operation_locked() {
  if (!operation_active_) return;
  Rp2350I2cEventSource::cancel(controller());
  reset_hardware();
  release_buffers();
  operation_complete_ = false;
  operation_active_ = false;
}

void I2cBusResource::abort_operation() {
  Locker locker(resource_group()->event_source()->mutex());
  abort_operation_locked();
}

void I2cBusResource::abort_operation_for(I2cDeviceResource* device) {
  Locker locker(resource_group()->event_source()->mutex());
  if (operation_active_ && active_device_ == device) abort_operation_locked();
}

FinishOperationStatus I2cBusResource::finish_operation(
    I2cDeviceResource* device, uint8_t* destination,
    uint32_t destination_length, ControllerResult* result) {
  Locker locker(resource_group()->event_source()->mutex());
  if (!operation_active_ || active_device_ != device) {
    return FinishOperationStatus::INVALID_ARGUMENT;
  }
  if (!operation_complete_) return FinishOperationStatus::INVALID_STATE;
  *result = result_;
  if (*result == ControllerResult::OK && rx_length_ > destination_length) {
    return FinishOperationStatus::OUT_OF_BOUNDS;
  }
  if (*result == ControllerResult::OK && rx_length_ != 0) {
    memcpy(destination, rx_, rx_length_);
  }
  Rp2350I2cEventSource::cancel(controller());
  release_buffers();
  operation_complete_ = false;
  operation_active_ = false;
  return FinishOperationStatus::OK;
}

MODULE_IMPLEMENTATION(i2c, MODULE_I2C)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Rp2350I2cEventSource* event_source = Rp2350I2cEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);
  I2cResourceGroup* group = _new I2cResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(bus_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl, bool, pullup);
  int controller = pins_to_controller(sda, scl);
  if (controller < 0) FAIL(INVALID_ARGUMENT);
  if (is_restricted_pin(sda) || is_restricted_pin(scl)) FAIL(PERMISSION_DENIED);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (!gpio_pool_take(sda)) FAIL(ALREADY_IN_USE);
  if (!gpio_pool_take(scl)) {
    gpio_pool_put(sda);
    FAIL(ALREADY_IN_USE);
  }
  if (!reserve_controller(controller)) {
    gpio_pool_put(scl);
    gpio_pool_put(sda);
    FAIL(ALREADY_IN_USE);
  }

  I2cBusResource* bus = _new I2cBusResource(
      group, controller, sda, scl);
  if (bus == null) {
    release_controller(controller);
    gpio_pool_put(scl);
    gpio_pool_put(sda);
    FAIL(MALLOC_FAILED);
  }

  i2c_init(bus->instance(), 100000);
  gpio_set_function(sda, GPIO_FUNC_I2C);
  gpio_set_function(scl, GPIO_FUNC_I2C);
  gpio_set_pulls(sda, pullup, false);
  gpio_set_pulls(scl, pullup, false);
  group->register_resource(bus);
  proxy->set_external_address(bus);
  return proxy;
}

PRIMITIVE(bus_close) {
  ARGS(I2cBusResource, bus);
  if (bus->device_count() != 0) FAIL(ALREADY_IN_USE);
  bus->resource_group()->unregister_resource(bus);
  bus_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(bus_probe) {
  ARGS(I2cBusResource, bus, uint16, address, int, timeout_ms);
  USE(bus);
  if (address > 0x7f || timeout_ms <= 0) FAIL(INVALID_ARGUMENT);
  // DW_apb_i2c attaches START/STOP to a data command and cannot issue an
  // address-only transfer. Reading or writing a byte would have target side
  // effects, so do not silently approximate the Bus.test contract.
  FAIL(UNIMPLEMENTED);
}

PRIMITIVE(bus_probe_finish) { FAIL(INVALID_STATE); }

PRIMITIVE(bus_abort_controller_operation) {
  ARGS(I2cBusResource, bus);
  bus->abort_operation();
  return process->null_object();
}

PRIMITIVE(device_create) {
  ARGS(I2cBusResource, bus, int, address_bit_size, uint16, address,
       uint32, frequency_hz, uint32, timeout_us, bool, disable_ack_check);
  if (address_bit_size != 7 || address > 0x7f) FAIL(INVALID_ARGUMENT);
  if (!frequency_is_supported(frequency_hz)) FAIL(INVALID_ARGUMENT);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  I2cDeviceResource* device = _new I2cDeviceResource(
      bus->resource_group(), bus, address, frequency_hz, timeout_us,
      disable_ack_check);
  if (device == null) FAIL(MALLOC_FAILED);
  bus->resource_group()->register_resource(device);
  proxy->set_external_address(device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(I2cDeviceResource, device);
  device->resource_group()->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(device_transfer_start) {
  ARGS(I2cDeviceResource, device, Blob, tx, int, rx_length);
  if (rx_length < 0) FAIL(OUT_OF_RANGE);
  if (tx.length() == 0 && rx_length == 0) FAIL(INVALID_ARGUMENT);
  uint8_t* tx_copy = null;
  uint8_t* rx_copy = null;
  if (tx.length() != 0) {
    tx_copy = unvoid_cast<uint8_t*>(malloc(tx.length()));
    if (tx_copy == null) FAIL(MALLOC_FAILED);
    memcpy(tx_copy, tx.address(), tx.length());
  }
  if (rx_length != 0) {
    rx_copy = unvoid_cast<uint8_t*>(malloc(rx_length));
    if (rx_copy == null) {
      free(tx_copy);
      FAIL(MALLOC_FAILED);
    }
  }

  bool started = device->bus()->start_operation(
      device, device->address(), device->frequency(), device->timeout_us(),
      device->disable_ack_check(), tx_copy, tx.length(), rx_copy, rx_length);
  if (!started) {
    free(rx_copy);
    free(tx_copy);
    FAIL(ALREADY_IN_USE);
  }
  return process->null_object();
}

PRIMITIVE(device_transfer_finish) {
  ARGS(I2cDeviceResource, device, MutableBlob, buffer, int, length);
  if (length < 0 || length > buffer.length()) FAIL(OUT_OF_BOUNDS);
  I2cBusResource* bus = device->bus();
  ControllerResult result;
  FinishOperationStatus status = bus->finish_operation(
      device, buffer.address(), length, &result);
  if (status == FinishOperationStatus::INVALID_ARGUMENT) FAIL(INVALID_ARGUMENT);
  if (status == FinishOperationStatus::INVALID_STATE) FAIL(INVALID_STATE);
  if (status == FinishOperationStatus::OUT_OF_BOUNDS) FAIL(OUT_OF_BOUNDS);
  return Smi::from(static_cast<int>(result));
}

static bool valid_target_address(int bits, uint16_t address, bool broadcast) {
  if (bits == 7) return address <= 0x7f;
  return bits == 10 && address <= 0x3ff && !broadcast;
}

PRIMITIVE(target_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Rp2350I2cEventSource* source = Rp2350I2cEventSource::instance();
  if (source == null) FAIL(ALREADY_CLOSED);
  I2cTargetResourceGroup* group = _new I2cTargetResourceGroup(process, source);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(target_create) {
  ARGS(I2cTargetResourceGroup, group, int, sda, int, scl,
       int, address_bit_size, uint16, address, uint32, send_buffer_size,
       uint32, receive_buffer_size, bool, pullup, bool, allow_power_down,
       bool, broadcast, Blob, default_response);
  int controller = pins_to_controller(sda, scl);
  if (controller < 0 || !valid_target_address(address_bit_size, address, broadcast) ||
      send_buffer_size == 0 || receive_buffer_size == 0 ||
      default_response.length() == 0 || default_response.length() > 32) {
    FAIL(INVALID_ARGUMENT);
  }
  if (allow_power_down) FAIL(UNSUPPORTED);
  if (is_restricted_pin(sda) || is_restricted_pin(scl)) FAIL(PERMISSION_DENIED);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  if (!gpio_pool_take(sda)) FAIL(ALREADY_IN_USE);
  if (!gpio_pool_take(scl)) {
    gpio_pool_put(sda);
    FAIL(ALREADY_IN_USE);
  }
  if (!reserve_controller(controller)) {
    gpio_pool_put(scl);
    gpio_pool_put(sda);
    FAIL(ALREADY_IN_USE);
  }
  I2cTargetResource* target = _new I2cTargetResource(group, controller, sda, scl);
  if (target == null) {
    release_controller(controller);
    gpio_pool_put(scl);
    gpio_pool_put(sda);
    FAIL(MALLOC_FAILED);
  }
  if (!target->initialize_buffers(send_buffer_size, receive_buffer_size,
                                  default_response.address(),
                                  default_response.length())) {
    delete target;
    FAIL(MALLOC_FAILED);
  }
  gpio_set_function(sda, GPIO_FUNC_I2C);
  gpio_set_function(scl, GPIO_FUNC_I2C);
  gpio_set_pulls(sda, pullup, false);
  gpio_set_pulls(scl, pullup, false);
  target->initialize(address, address_bit_size == 10, broadcast);
  group->register_resource(target);
  proxy->set_external_address(target);
  return proxy;
}

PRIMITIVE(target_close) {
  ARGS(I2cTargetResourceGroup, group, I2cTargetResource, target);
  group->unregister_resource(target);
  target_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(target_receive) {
  ARGS(I2cTargetResource, target);
  uint32_t length = target->next_receive_length();
  if (length == 0) return process->null_object();
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  target->take_receive(ByteArray::Bytes(result).address());
  return result;
}

PRIMITIVE(target_write) {
  ARGS(I2cTargetResource, target, Blob, buffer, uint32, offset);
  uint32_t buffer_length = static_cast<uint32_t>(buffer.length());
  if (offset > buffer_length) FAIL(OUT_OF_BOUNDS);
  uint32_t written = target->write(buffer.address() + offset,
                                   buffer_length - offset);
  ASSERT(written <= static_cast<uint32_t>(Smi::MAX_SMI_VALUE));
  return Smi::from(static_cast<word>(written));
}

PRIMITIVE(target_set_write_pending) {
  ARGS(I2cTargetResource, target, bool, pending);
  target->set_write_pending(pending);
  return process->null_object();
}

PRIMITIVE(target_set_handler_mode) {
  ARGS(I2cTargetResource, target, bool, enabled);
  target->set_handler_mode(enabled);
  return process->null_object();
}

PRIMITIVE(target_take_request_count) {
  ARGS(I2cTargetResource, target);
  return Smi::from(target->take_request_count());
}

PRIMITIVE(target_dropped_receive_count) {
  ARGS(I2cTargetResource, target);
  return Smi::from(target->dropped_receive_count());
}

PRIMITIVE(register_target_create) {
  ARGS(I2cResourceGroup, group, int, sda, int, scl,
       int, address_bit_size, uint16, address, uint32, register_count,
       uint32, register_address_byte_size, uint32, receive_buffer_size,
       bool, pullup, bool, allow_power_down, bool, broadcast);
  int controller = pins_to_controller(sda, scl);
  uint32_t addressable = register_address_byte_size == 1 ? 256 : 65536;
  if (controller < 0 || !valid_target_address(address_bit_size, address, broadcast) ||
      register_count == 0 ||
      (register_address_byte_size != 1 && register_address_byte_size != 2) ||
      register_count > addressable ||
      receive_buffer_size < register_address_byte_size) FAIL(INVALID_ARGUMENT);
  if (allow_power_down) FAIL(UNSUPPORTED);
  if (is_restricted_pin(sda) || is_restricted_pin(scl)) FAIL(PERMISSION_DENIED);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  uint8_t* registers = unvoid_cast<uint8_t*>(calloc(register_count, 1));
  if (registers == null) FAIL(MALLOC_FAILED);
  if (!gpio_pool_take(sda)) {
    free(registers);
    FAIL(ALREADY_IN_USE);
  }
  if (!gpio_pool_take(scl)) {
    gpio_pool_put(sda);
    free(registers);
    FAIL(ALREADY_IN_USE);
  }
  if (!reserve_controller(controller)) {
    gpio_pool_put(scl);
    gpio_pool_put(sda);
    free(registers);
    FAIL(ALREADY_IN_USE);
  }
  I2cRegisterTargetResource* target = _new I2cRegisterTargetResource(
      group, controller, sda, scl, registers, register_count,
      register_address_byte_size);
  if (target == null) {
    release_controller(controller);
    gpio_pool_put(scl);
    gpio_pool_put(sda);
    free(registers);
    FAIL(MALLOC_FAILED);
  }
  if (!target->initialize_buffer(receive_buffer_size) ||
      !target->allocate_scratch(receive_buffer_size)) {
    delete target;
    FAIL(MALLOC_FAILED);
  }
  gpio_set_function(sda, GPIO_FUNC_I2C);
  gpio_set_function(scl, GPIO_FUNC_I2C);
  gpio_set_pulls(sda, pullup, false);
  gpio_set_pulls(scl, pullup, false);
  target->initialize(address, address_bit_size == 10, broadcast);
  group->register_resource(target);
  proxy->set_external_address(target);
  return proxy;
}

PRIMITIVE(register_target_close) {
  ARGS(I2cResourceGroup, group, I2cRegisterTargetResource, target);
  group->unregister_resource(target);
  target_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(register_target_get) {
  ARGS(I2cRegisterTargetResource, target, uint32, index);
  if (index >= target->register_count()) FAIL(OUT_OF_BOUNDS);
  return Smi::from(target->get(index));
}

PRIMITIVE(register_target_set) {
  ARGS(I2cRegisterTargetResource, target, uint32, index, uint8, value);
  if (index >= target->register_count()) FAIL(OUT_OF_BOUNDS);
  target->set(index, value);
  return Smi::from(value);
}

PRIMITIVE(register_target_read) {
  ARGS(I2cRegisterTargetResource, target, uint32, index, uint32, length);
  if (index > target->register_count() ||
      length > target->register_count() - index) FAIL(OUT_OF_BOUNDS);
  ByteArray* result = process->allocate_byte_array(length);
  if (result == null) FAIL(ALLOCATION_FAILED);
  target->read(index, ByteArray::Bytes(result).address(), length);
  return result;
}

PRIMITIVE(register_target_write) {
  ARGS(I2cRegisterTargetResource, target, uint32, index, Blob, bytes);
  uint32_t length = static_cast<uint32_t>(bytes.length());
  if (index > target->register_count() ||
      length > target->register_count() - index) FAIL(OUT_OF_BOUNDS);
  target->write(index, bytes.address(), length);
  return process->null_object();
}

PRIMITIVE(register_target_dropped_write_count) {
  ARGS(I2cRegisterTargetResource, target);
  return Smi::from(target->dropped_write_count());
}

}  // namespace toit

#endif  // TOIT_RP2350
