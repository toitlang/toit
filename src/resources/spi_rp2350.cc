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

#include <limits.h>
#include <string.h>

#include "hardware/clocks.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/regs/spi.h"
#include "hardware/resets.h"
#include "hardware/spi.h"
#include "hardware/sync.h"

extern "C" {
  #include "FreeRTOS.h"
}

#include "../event_sources/event_rp2350.h"
#include "../event_sources/spi_rp2350.h"
#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"

namespace toit {

// Shared GPIO ownership is implemented by gpio_rp2350.cc. SPI accepts only
// numeric GP identifiers and owns every configured pin until teardown.
bool gpio_pool_take(int pin);
void gpio_pool_put(int pin);

static const int kControllerCount = 2;
static const uint32_t kTransferDoneState = 1 << 0;
static const uint32_t kTargetReadyState = 1 << 0;
static const uint32_t kTargetDoneState = 1 << 1;
static const uint32_t kBufferTargetReceivedState = 1 << 2;
static const uint32_t kBufferTargetStoppedState = 1 << 3;
static const uint32_t kBufferTargetArmedState = 1 << 4;
static const uint32_t kFifoDepth = 8;
static const uint32_t kTargetNonDmaMaximum = 64;
static const uint32_t kTargetMaximum = 4092;

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

static bool is_valid_pin(int pin) {
  return pin >= 0 && pin < static_cast<int>(NUM_BANK0_GPIOS);
}

static bool is_restricted_pin(int pin) {
#ifdef PICO_PSRAM_CS_PIN
  return pin == PICO_PSRAM_CS_PIN;
#else
  USE(pin);
  return false;
#endif
}

// RP2350B repeats the SPI routes every 16 GPIOs. Within each group of four,
// RX, CSn, SCK, and TX occupy offsets 0, 1, 2, and 3. Blocks of eight select
// SPI0 and SPI1 alternately.
static int pin_controller(int pin, int role) {
  if (!is_valid_pin(pin) || (pin & 3) != role) return -1;
  return (pin >> 3) & 1;
}

static int pins_to_controller(int mosi, int miso, int clock) {
  int controller = pin_controller(clock, 2);
  if (controller < 0 || (mosi < 0 && miso < 0)) return -1;
  if (mosi < -1 || miso < -1) return -1;
  if (mosi >= 0 && pin_controller(mosi, 3) != controller) return -1;
  if (miso >= 0 && pin_controller(miso, 0) != controller) return -1;
  return controller;
}

// A target observes MOSI on the controller RX route and drives MISO on the
// controller TX route. The public names describe the target's perspective.
static int target_pins_to_controller(int mosi, int miso, int clock, int cs) {
  int controller = pin_controller(clock, 2);
  if (controller < 0 || (mosi < 0 && miso < 0)) return -1;
  if (mosi < -1 || miso < -1 || cs < 0) return -1;
  if (mosi >= 0 && pin_controller(mosi, 0) != controller) return -1;
  if (miso >= 0 && pin_controller(miso, 3) != controller) return -1;
  if (pin_controller(cs, 1) != controller) return -1;
  return controller;
}

static uint8_t reverse_byte(uint8_t value) {
  value = static_cast<uint8_t>((value >> 4) | (value << 4));
  value = static_cast<uint8_t>(((value & 0xcc) >> 2) |
                               ((value & 0x33) << 2));
  return static_cast<uint8_t>(((value & 0xaa) >> 1) |
                              ((value & 0x55) << 1));
}

static bool frequency_is_supported(uint32_t frequency) {
  if (frequency == 0) return false;
  uint32_t source = clock_get_hz(clk_peri);
  uint32_t minimum = source / (254u * 256u) + 1;
  uint32_t maximum = source / 2;
  return frequency >= minimum && frequency <= maximum;
}

enum class FinishStatus {
  COMPLETE,
  PENDING,
  INVALID_STATE,
  OUT_OF_BOUNDS,
  HARDWARE_ERROR,
};

class SpiDevice;
class SpiTargetResourceBase;

class Rp2350SpiEventSource : public Rp2350PeripheralEventSource {
 public:
  static Rp2350SpiEventSource* instance() { return instance_; }

  Rp2350SpiEventSource();
  ~Rp2350SpiEventSource() override;

  bool start_operation(SpiDevice* device);
  FinishStatus finish_operation(SpiDevice* device, uint8_t* destination,
                                uint32_t destination_size, uint32_t from,
                                bool read);
  bool abort_operation(SpiDevice* device);

  bool register_target(SpiTargetResourceBase* target);
  void notify_target(SpiTargetResourceBase* target, uint32_t state);
  static void notify_target_from_isr(SpiTargetResourceBase* target,
                                     uint32_t state);

  static void notify_from_isr(int controller);
  static void request_idle_poll_from_isr(int controller);
  bool poll() override;

 protected:
  void on_unregister_resource(Locker& locker, Resource* resource) override;

 private:
  static void spi0_interrupt();
  static void spi1_interrupt();
  static void interrupt(int controller);
  static void dma_interrupt();

  void clear_operation_locked(int controller);
  void dispatch_pending(const Locker& locker);

  static Rp2350SpiEventSource* instance_;
  static SpiDevice* volatile active_[kControllerCount];
  static SpiTargetResourceBase* volatile targets_[kControllerCount];
  static uint32_t pending_[kControllerCount];
  static uint32_t target_pending_[kControllerCount];
  static uint32_t idle_poll_mask_;
};

class SpiResourceGroup : public ResourceGroup {
 public:
  TAG(SpiResourceGroup);

  SpiResourceGroup(Process* process, Rp2350SpiEventSource* event_source,
                   int controller, int mosi, int miso, int clock)
      : ResourceGroup(process, event_source)
      , controller_(controller)
      , mosi_(mosi)
      , miso_(miso)
      , clock_(clock) {}

  ~SpiResourceGroup() override {
    ASSERT(device_count_ == 0);
    ASSERT(active_device_ == null);
    spi_deinit(instance());
    if (mosi_ >= 0) gpio_pool_put(mosi_);
    if (miso_ >= 0) gpio_pool_put(miso_);
    gpio_pool_put(clock_);
    release_controller(controller_);
  }

  uint32_t on_event(Resource* resource, word data,
                    uint32_t state) override {
    USE(resource);
    return state | static_cast<uint32_t>(data);
  }

  void on_register_resource(Resource* resource) override {
    USE(resource);
    device_count_++;
  }

  void on_unregister_resource(Resource* resource) override;

  int controller() const { return controller_; }
  spi_inst_t* instance() const { return spi_get_instance(controller_); }
  SpiDevice* active_device() const { return active_device_; }
  void set_active_device(SpiDevice* device) { active_device_ = device; }
  SpiDevice* reserved_device() const { return reserved_device_; }
  void set_reserved_device(SpiDevice* device) { reserved_device_ = device; }

  void ensure_configuration(uint32_t frequency, uint8_t mode) {
    if (!initialized_) {
      spi_init(instance(), frequency);
      initialized_ = true;
      configured_frequency_ = frequency;
      configured_mode_ = 0;
    } else if (configured_frequency_ != frequency) {
      spi_set_baudrate(instance(), frequency);
      configured_frequency_ = frequency;
    }
    if (configured_mode_ != mode) {
      spi_set_format(instance(), 8,
                     (mode & 2) ? SPI_CPOL_1 : SPI_CPOL_0,
                     (mode & 1) ? SPI_CPHA_1 : SPI_CPHA_0,
                     SPI_MSB_FIRST);
      configured_mode_ = mode;
    }
  }

  void invalidate_configuration() { initialized_ = false; }

 private:
  int controller_;
  int mosi_;
  int miso_;
  int clock_;
  int device_count_ = 0;
  SpiDevice* active_device_ = null;
  SpiDevice* reserved_device_ = null;
  bool initialized_ = false;
  uint32_t configured_frequency_ = 0;
  uint8_t configured_mode_ = 0;
};

class SpiDevice : public Resource {
 public:
  TAG(SpiDevice);

  SpiDevice(SpiResourceGroup* group, int cs, int dc,
            uint32_t frequency, uint8_t mode,
            uint8_t command_bits, uint8_t address_bits)
      : Resource(group)
      , group_(group)
      , cs_(cs)
      , dc_(dc)
      , frequency_(frequency)
      , mode_(mode)
      , command_bits_(command_bits)
      , address_bits_(address_bits) {}

  ~SpiDevice() override {
    ASSERT(!operation_active_);
    if (cs_ >= 0) {
      gpio_put(cs_, 1);
      gpio_pool_put(cs_);
    }
    if (dc_ >= 0) gpio_pool_put(dc_);
  }

  int controller() const { return group_->controller(); }
  SpiResourceGroup* group() const { return group_; }
  int cs() const { return cs_; }
  int dc() const { return dc_; }
  int command_bits() const { return command_bits_; }
  int address_bits() const { return address_bits_; }
  bool operation_complete() const { return operation_complete_; }
  void set_dc_value(int value) { dc_value_ = value; }

  void prepare_operation(uint8_t* buffer, uint32_t prefix_length,
                         uint32_t length, bool read, bool keep_cs) {
    ASSERT(!operation_active_ && buffer_ == null);
    buffer_ = buffer;
    prefix_length_ = prefix_length;
    length_ = length;
    total_length_ = prefix_length + length;
    read_ = read;
    keep_cs_ = keep_cs;
  }

  void abandon_prepared_operation() {
    ASSERT(!operation_active_);
    free(buffer_);
    clear_operation_fields();
  }

  bool start_operation_locked();
  void handle_interrupt_from_isr();
  bool finish_if_idle_locked();
  FinishStatus finish_operation_locked(uint8_t* destination,
                                       uint32_t destination_size,
                                       uint32_t from, bool read);
  void abort_operation_locked();
  void set_interrupts_enabled(bool enabled);

 private:
  void fill_fifo();
  void complete_from_isr();
  void complete_locked();
  void cleanup_locked();
  void clear_operation_fields();

  SpiResourceGroup* group_;
  int cs_;
  int dc_;
  uint32_t frequency_;
  uint8_t mode_;
  uint8_t command_bits_;
  uint8_t address_bits_;

  uint8_t* buffer_ = null;
  uint32_t prefix_length_ = 0;
  uint32_t length_ = 0;
  uint32_t total_length_ = 0;
  volatile uint32_t transmitted_ = 0;
  volatile uint32_t received_ = 0;
  bool read_ = false;
  bool keep_cs_ = false;
  int dc_value_ = 0;
  volatile bool operation_active_ = false;
  volatile bool operation_complete_ = false;
  volatile bool hardware_error_ = false;
};

class SpiTargetResourceGroup : public ResourceGroup {
 public:
  TAG(SpiTargetResourceGroup);

  SpiTargetResourceGroup(Process* process, Rp2350SpiEventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data,
                    uint32_t state) override {
    USE(resource);
    return state | static_cast<uint32_t>(data);
  }
};

class SpiTargetResourceBase : public Resource,
                              public Rp2350SpiTargetClient {
 public:
  SpiTargetResourceBase(SpiTargetResourceGroup* group,
                        int controller, int mosi, int miso,
                        int clock, int cs, uint8_t mode,
                        bool transmit_lsb_first, bool receive_lsb_first,
                        bool dma, bool complete_at_limit)
      : Resource(group)
      , controller_(controller)
      , mosi_(mosi)
      , miso_(miso)
      , clock_(clock)
      , cs_(cs)
      , mode_(mode)
      , transmit_lsb_first_(transmit_lsb_first)
      , receive_lsb_first_(receive_lsb_first)
      , dma_(dma)
      , complete_at_limit_(complete_at_limit) {}

  ~SpiTargetResourceBase() override {
    ASSERT(!initialized_);
    delete transport_;
    gpio_pool_put(cs_);
    gpio_pool_put(clock_);
    if (miso_ >= 0) gpio_pool_put(miso_);
    if (mosi_ >= 0) gpio_pool_put(mosi_);
    release_controller(controller_);
  }

  int controller() const { return controller_; }
  int cs() const { return cs_; }
  bool dma() const { return dma_; }
  bool transmit_lsb_first() const { return transmit_lsb_first_; }
  bool receive_lsb_first() const { return receive_lsb_first_; }

  bool initialize();
  void shutdown_locked();
  void handle_spi_interrupt_from_isr() {
    if (transport_ != null) transport_->handle_spi_interrupt_from_isr();
  }
  void handle_dma_interrupt_from_isr() {
    if (transport_ != null) transport_->handle_dma_interrupt_from_isr();
  }

 protected:
  bool arm(uint8_t* tx_buffer, uint8_t* rx_buffer,
           uint32_t size, bool from_isr);
  void cancel_arm_from_task();
  void notify(uint32_t state) {
    Rp2350SpiEventSource::instance()->notify_target(this, state);
  }
  void notify_from_isr(uint32_t state) {
    Rp2350SpiEventSource::notify_target_from_isr(this, state);
  }

  virtual void on_armed(bool from_isr) = 0;
  virtual void on_transaction_end(
      uint32_t bytes, bool transfer_error, bool from_isr) = 0;

 private:
  void target_armed(bool from_isr) override { on_armed(from_isr); }
  void target_complete(uint32_t complete_bytes,
                       bool transfer_error,
                       bool from_isr) override {
    on_transaction_end(complete_bytes, transfer_error, from_isr);
  }

  int controller_;
  int mosi_;
  int miso_;
  int clock_;
  int cs_;
  uint8_t mode_;
  bool transmit_lsb_first_;
  bool receive_lsb_first_;
  bool dma_;
  bool complete_at_limit_;
  Rp2350SpiTargetTransport* transport_ = null;
  bool initialized_ = false;
};

class SpiTargetResource : public SpiTargetResourceBase {
 public:
  TAG(SpiTargetResource);

  SpiTargetResource(SpiTargetResourceGroup* group,
                    int controller, int mosi, int miso,
                    int clock, int cs, uint8_t mode,
                    bool transmit_lsb_first, bool receive_lsb_first,
                    bool dma,
                    uint32_t max_transfer_size)
      : SpiTargetResourceBase(group, controller, mosi, miso, clock, cs,
                              mode, transmit_lsb_first, receive_lsb_first,
                              dma, true)
      , max_transfer_size_(max_transfer_size) {}

  ~SpiTargetResource() override {
    free(tx_buffer_);
    free(rx_buffer_);
  }

  uint32_t max_transfer_size() const { return max_transfer_size_; }
  bool operation_in_flight() const { return operation_in_flight_; }

  bool start(uint8_t* tx_buffer, uint8_t* rx_buffer,
             uint32_t receive_size, uint32_t transfer_size) {
    if (operation_in_flight_) return false;
    tx_buffer_ = tx_buffer;
    rx_buffer_ = rx_buffer;
    receive_size_ = receive_size;
    transfer_size_ = transfer_size;
    transferred_ = 0;
    operation_complete_ = false;
    operation_in_flight_ = true;
    if (arm(tx_buffer_, rx_buffer_, transfer_size_, false)) return true;
    clear_operation();
    return false;
  }

  bool abort();
  int finish(uint8_t* destination, uint32_t destination_size);

 protected:
  void on_armed(bool from_isr) override {
    if (from_isr) {
      notify_from_isr(kTargetReadyState);
    } else {
      notify(kTargetReadyState);
    }
  }

  void on_transaction_end(
      uint32_t bytes, bool transfer_error, bool from_isr) override {
    transferred_ = bytes;
    hardware_error_ = transfer_error;
    operation_complete_ = true;
    if (from_isr) {
      notify_from_isr(kTargetDoneState);
    } else {
      notify(kTargetDoneState);
    }
  }

 private:
  void clear_operation() {
    free(tx_buffer_);
    free(rx_buffer_);
    tx_buffer_ = null;
    rx_buffer_ = null;
    receive_size_ = 0;
    transfer_size_ = 0;
    transferred_ = 0;
    hardware_error_ = false;
    operation_complete_ = false;
    operation_in_flight_ = false;
  }

  uint32_t max_transfer_size_;
  uint8_t* tx_buffer_ = null;
  uint8_t* rx_buffer_ = null;
  uint32_t receive_size_ = 0;
  uint32_t transfer_size_ = 0;
  volatile uint32_t transferred_ = 0;
  volatile bool operation_complete_ = false;
  volatile bool hardware_error_ = false;
  bool operation_in_flight_ = false;
};

class SpiBufferTargetResource : public SpiTargetResourceBase {
 public:
  TAG(SpiBufferTargetResource);

  SpiBufferTargetResource(SpiTargetResourceGroup* group,
                          int controller, int mosi, int miso,
                          int clock, int cs, uint8_t mode,
                          bool transmit_lsb_first, bool receive_lsb_first,
                          bool dma,
                          uint8_t* response, uint8_t* receive_storage,
                          uint32_t* receive_indices,
                          uint32_t* receive_lengths,
                          uint32_t* free_indices,
                          uint32_t size, uint32_t queue_depth,
                          bool can_receive, bool can_transmit)
      : SpiTargetResourceBase(group, controller, mosi, miso, clock, cs,
                              mode, transmit_lsb_first, receive_lsb_first,
                              dma, false)
      , response_(response)
      , receive_storage_(receive_storage)
      , receive_indices_(receive_indices)
      , receive_lengths_(receive_lengths)
      , free_indices_(free_indices)
      , size_(size)
      , queue_depth_(queue_depth)
      , can_receive_(can_receive)
      , can_transmit_(can_transmit) {
    if (can_receive_) {
      free_count_ = queue_depth_;
      for (uint32_t i = 0; i < queue_depth_; i++) free_indices_[i] = i + 1;
    }
  }

  ~SpiBufferTargetResource() override {
    free(response_);
    free(receive_storage_);
    free(receive_indices_);
    free(receive_lengths_);
    free(free_indices_);
  }

  uint32_t size() const { return size_; }
  bool can_receive() const { return can_receive_; }
  bool can_transmit() const { return can_transmit_; }

  bool start();
  bool request_stop();
  int get(uint32_t index) const;
  void set(uint32_t index, uint8_t value);
  void read(uint32_t index, uint8_t* destination, uint32_t length) const;
  void write(uint32_t index, const uint8_t* source, uint32_t length);
  int receive(uint8_t* destination);
  word dropped_receive_count() const;

 protected:
  void on_armed(bool from_isr) override;
  void on_transaction_end(
      uint32_t bytes, bool transfer_error, bool from_isr) override;

 private:
  uint8_t* active_receive_buffer() const {
    return receive_storage_ + active_receive_index_ * size_;
  }
  void store_response(uint32_t index, uint8_t value) {
    response_[index] = value;
  }
  uint8_t load_response(uint32_t index) const {
    return response_[index];
  }

  uint8_t* response_;
  uint8_t* receive_storage_;
  uint32_t* receive_indices_;
  uint32_t* receive_lengths_;
  uint32_t* free_indices_;
  uint32_t size_;
  uint32_t queue_depth_;
  bool can_receive_;
  bool can_transmit_;
  volatile bool running_ = false;
  volatile bool stopping_ = false;
  volatile bool initially_armed_ = false;
  volatile bool rearm_failed_ = false;
  volatile bool transfer_error_ = false;
  volatile uint32_t receive_head_ = 0;
  volatile uint32_t receive_count_ = 0;
  volatile uint32_t free_count_ = 0;
  volatile uint32_t active_receive_index_ = 0;
  volatile word dropped_receive_count_ = 0;
};

class Pl022SpiTargetTransport : public Rp2350SpiTargetTransport {
 public:
  Pl022SpiTargetTransport(const Rp2350SpiTargetTransportConfig& config,
                          Rp2350SpiTargetClient* client,
                          int tx_dma_channel, int rx_dma_channel)
      : config_(config)
      , client_(client)
      , tx_dma_channel_(tx_dma_channel)
      , rx_dma_channel_(rx_dma_channel) {}

  ~Pl022SpiTargetTransport() override {
    ASSERT(!initialized_);
  }

  bool initialize();
  bool arm(uint8_t* transmit, uint8_t* receive,
           uint32_t size, bool from_isr) override;
  void abort() override;
  void shutdown() override;
  void handle_spi_interrupt_from_isr() override;
  void handle_dma_interrupt_from_isr() override;

 private:
  static Pl022SpiTargetTransport* volatile instances_[kControllerCount];
  static void cs0_interrupt() { cs_interrupt(0); }
  static void cs1_interrupt() { cs_interrupt(1); }
  static void cs_interrupt(int controller);

  spi_inst_t* spi() const { return spi_get_instance(config_.controller); }
  spi_hw_t* hardware() const { return spi_get_hw(spi()); }
  void configure_hardware();
  void start_hardware(bool from_isr);
  uint32_t stop_hardware();
  void fill_fifo();
  void drain_fifo();
  void complete(bool transfer_error, bool from_isr);
  void reached_limit(bool transfer_error);
  void abort_dma_channel(int channel);

  Rp2350SpiTargetTransportConfig config_;
  Rp2350SpiTargetClient* client_;
  int tx_dma_channel_;
  int rx_dma_channel_;
  bool initialized_ = false;
  volatile bool active_ = false;
  volatile bool hardware_armed_ = false;
  volatile bool waiting_for_cs_inactive_ = false;
  volatile bool limit_reached_ = false;
  volatile bool transfer_error_ = false;
  uint8_t* volatile transmit_ = null;
  uint8_t* volatile receive_ = null;
  volatile uint32_t size_ = 0;
  volatile uint32_t transmitted_ = 0;
  volatile uint32_t received_ = 0;
};

Pl022SpiTargetTransport* volatile
    Pl022SpiTargetTransport::instances_[kControllerCount] = {};

bool Pl022SpiTargetTransport::initialize() {
  ASSERT(!initialized_ && instances_[config_.controller] == null);
  instances_[config_.controller] = this;

  gpio_pull_up(config_.cs);
  if (config_.mosi >= 0) gpio_set_function(config_.mosi, GPIO_FUNC_SPI);
  if (config_.miso >= 0) gpio_set_function(config_.miso, GPIO_FUNC_SPI);
  gpio_set_function(config_.clock, GPIO_FUNC_SPI);
  gpio_set_function(config_.cs, GPIO_FUNC_SPI);

  configure_hardware();

  irq_handler_t handler = config_.controller == 0
      ? cs0_interrupt
      : cs1_interrupt;
  gpio_add_raw_irq_handler_with_order_priority_masked64(
      1ull << config_.cs, handler,
      PICO_SHARED_IRQ_HANDLER_DEFAULT_ORDER_PRIORITY);
  gpio_acknowledge_irq(config_.cs, GPIO_IRQ_EDGE_RISE);
  gpio_set_irq_enabled(config_.cs, GPIO_IRQ_EDGE_RISE, true);
  initialized_ = true;
  return true;
}

void Pl022SpiTargetTransport::configure_hardware() {
  // PL022 has no FIFO-clear register. Resetting the peripheral is the only
  // documented way to guarantee that a short transaction's prefetched TX
  // tail cannot become the start of the next transaction.
  reset_block_num(SPI_RESET_NUM(spi()));
  unreset_block_num_wait_blocking(SPI_RESET_NUM(spi()));
  spi_set_baudrate(spi(), 1000000);
  spi_set_format(spi(), 8,
                 (config_.mode & 2) ? SPI_CPOL_1 : SPI_CPOL_0,
                 SPI_CPHA_1, SPI_MSB_FIRST);
  spi_set_slave(spi(), true);
  hw_clear_bits(&hardware()->cr1, SPI_SSPCR1_SSE_BITS);
  hardware()->dmacr = 0;
  hardware()->imsc = 0;
  if (config_.miso < 0) {
    hw_set_bits(&hardware()->cr1, SPI_SSPCR1_SOD_BITS);
  }
}

bool Pl022SpiTargetTransport::arm(
    uint8_t* transmit, uint8_t* receive,
    uint32_t size, bool from_isr) {
  uint32_t interrupt_status = save_and_disable_interrupts();
  if (!initialized_ || active_ || size == 0) {
    restore_interrupts(interrupt_status);
    return false;
  }
  // A controller-side device constructor can toggle CS before the target is
  // mounted. Do not let that stale rising edge complete the new transaction.
  gpio_acknowledge_irq(config_.cs, GPIO_IRQ_EDGE_RISE);
  transmit_ = transmit;
  receive_ = receive;
  size_ = size;
  transmitted_ = 0;
  received_ = 0;
  transfer_error_ = false;
  limit_reached_ = false;
  active_ = true;
  if (gpio_get(config_.cs)) {
    waiting_for_cs_inactive_ = false;
    start_hardware(from_isr);
  } else {
    waiting_for_cs_inactive_ = true;
  }
  restore_interrupts(interrupt_status);
  return true;
}

void Pl022SpiTargetTransport::start_hardware(bool from_isr) {
  ASSERT(active_ && !hardware_armed_);
  spi_hw_t* hw = hardware();
  hw->imsc = 0;
  hw->dmacr = 0;
  hw_clear_bits(&hw->cr1, SPI_SSPCR1_SSE_BITS);
  for (uint32_t i = 0;
       i < kFifoDepth && (hw->sr & SPI_SSPSR_RNE_BITS) != 0;
       i++) {
    USE(hw->dr);
  }
  hw->icr = SPI_SSPICR_RORIC_BITS | SPI_SSPICR_RTIC_BITS;

  if (config_.dma) {
    dma_channel_config tx_config = dma_channel_get_default_config(
        tx_dma_channel_);
    channel_config_set_transfer_data_size(&tx_config, DMA_SIZE_8);
    channel_config_set_read_increment(&tx_config, true);
    channel_config_set_write_increment(&tx_config, false);
    channel_config_set_dreq(&tx_config, spi_get_dreq(spi(), true));
    dma_channel_configure(tx_dma_channel_, &tx_config,
                          &hw->dr, transmit_, size_, false);

    dma_channel_config rx_config = dma_channel_get_default_config(
        rx_dma_channel_);
    channel_config_set_transfer_data_size(&rx_config, DMA_SIZE_8);
    channel_config_set_read_increment(&rx_config, false);
    channel_config_set_write_increment(&rx_config, true);
    channel_config_set_dreq(&rx_config, spi_get_dreq(spi(), false));
    dma_channel_configure(rx_dma_channel_, &rx_config,
                          receive_, &hw->dr, size_, false);
    dma_channel_acknowledge_irq1(rx_dma_channel_);
    dma_channel_set_irq1_enabled(rx_dma_channel_, true);
    hw->dmacr = SPI_SSPDMACR_TXDMAE_BITS | SPI_SSPDMACR_RXDMAE_BITS;
    hardware_armed_ = true;
    hw_set_bits(&hw->cr1, SPI_SSPCR1_SSE_BITS);
    dma_start_channel_mask((1u << tx_dma_channel_) |
                           (1u << rx_dma_channel_));
  } else {
    fill_fifo();
    hw->imsc = SPI_SSPIMSC_TXIM_BITS |
               SPI_SSPIMSC_RXIM_BITS |
               SPI_SSPIMSC_RTIM_BITS |
               SPI_SSPIMSC_RORIM_BITS;
    hardware_armed_ = true;
    hw_set_bits(&hw->cr1, SPI_SSPCR1_SSE_BITS);
    irq_set_enabled(config_.controller == 0 ? SPI0_IRQ : SPI1_IRQ, true);
  }
  client_->target_armed(from_isr);
}

void Pl022SpiTargetTransport::abort_dma_channel(int channel) {
  dma_channel_set_irq1_enabled(channel, false);
  hw_clear_bits(&dma_channel_hw_addr(channel)->ctrl_trig,
                DMA_CH0_CTRL_TRIG_EN_BITS);
  dma_channel_abort(channel);
  dma_channel_acknowledge_irq1(channel);
}

uint32_t Pl022SpiTargetTransport::stop_hardware() {
  if (!hardware_armed_) return limit_reached_ ? size_ : received_;
  spi_hw_t* hw = hardware();
  hw->dmacr = 0;
  hw->imsc = 0;
  irq_set_enabled(config_.controller == 0 ? SPI0_IRQ : SPI1_IRQ, false);
  if ((hw->ris & SPI_SSPRIS_RORRIS_BITS) != 0) transfer_error_ = true;
  // Stop accepting clocks before retiring DMA, so cancellation and
  // full-limit completion have a bounded amount of peripheral work left.
  hw_clear_bits(&hw->cr1, SPI_SSPCR1_SSE_BITS);

  if (config_.dma) {
    abort_dma_channel(rx_dma_channel_);
    abort_dma_channel(tx_dma_channel_);
    uintptr_t receive_base = reinterpret_cast<uintptr_t>(receive_);
    uintptr_t receive_end = receive_base + size_;
    uintptr_t dma_write =
        dma_channel_hw_addr(rx_dma_channel_)->write_addr;
    if (dma_write < receive_base || dma_write > receive_end) {
      transfer_error_ = true;
      received_ = dma_write < receive_base ? 0 : size_;
    } else {
      // TRANS_COUNT is not a reliable progress value after abort. WRITE_ADDR
      // advances only when each byte write retires and is preserved by abort.
      received_ = static_cast<uint32_t>(dma_write - receive_base);
    }
    uint32_t rx_control = dma_channel_hw_addr(rx_dma_channel_)->ctrl_trig;
    uint32_t tx_control = dma_channel_hw_addr(tx_dma_channel_)->ctrl_trig;
    if (((rx_control | tx_control) & DMA_CH0_CTRL_TRIG_AHB_ERROR_BITS) != 0) {
      transfer_error_ = true;
    }
  }

  drain_fifo();
  hardware_armed_ = false;
  // Disabling SSE is not specified to empty the transmit FIFO. A peripheral
  // reset retires the unread TX tail before the next response is mounted.
  configure_hardware();
  return received_ > size_ ? size_ : received_;
}

void Pl022SpiTargetTransport::fill_fifo() {
  spi_hw_t* hw = hardware();
  uint32_t filled = 0;
  while (transmitted_ < size_ &&
         filled < kFifoDepth &&
         (hw->sr & SPI_SSPSR_TNF_BITS) != 0) {
    hw->dr = transmit_[transmitted_++];
    filled++;
  }
}

void Pl022SpiTargetTransport::drain_fifo() {
  spi_hw_t* hw = hardware();
  uint32_t drained = 0;
  while (drained < kFifoDepth &&
         (hw->sr & SPI_SSPSR_RNE_BITS) != 0) {
    uint8_t byte = static_cast<uint8_t>(hw->dr);
    if (received_ < size_) {
      receive_[received_++] = byte;
    }
    drained++;
  }
}

void Pl022SpiTargetTransport::complete(
    bool transfer_error, bool from_isr) {
  uint32_t received = stop_hardware();
  active_ = false;
  waiting_for_cs_inactive_ = !gpio_get(config_.cs);
  client_->target_complete(
      received, transfer_error || transfer_error_, from_isr);
}

void Pl022SpiTargetTransport::reached_limit(bool transfer_error) {
  if (config_.complete_at_limit) {
    complete(transfer_error, true);
  } else {
    stop_hardware();
    limit_reached_ = true;
    transfer_error_ |= transfer_error;
  }
}

void Pl022SpiTargetTransport::handle_spi_interrupt_from_isr() {
  if (!active_ || !hardware_armed_ || config_.dma) return;
  spi_hw_t* hw = hardware();
  uint32_t status = hw->mis;
  bool overrun = (status & SPI_SSPMIS_RORMIS_BITS) != 0;
  drain_fifo();
  hw->icr = SPI_SSPICR_RORIC_BITS | SPI_SSPICR_RTIC_BITS;
  fill_fifo();
  if (overrun || received_ >= size_) {
    reached_limit(overrun);
    return;
  }
  uint32_t masks = SPI_SSPIMSC_RXIM_BITS |
                   SPI_SSPIMSC_RTIM_BITS |
                   SPI_SSPIMSC_RORIM_BITS;
  if (transmitted_ < size_) masks |= SPI_SSPIMSC_TXIM_BITS;
  hw->imsc = masks;
}

void Pl022SpiTargetTransport::handle_dma_interrupt_from_isr() {
  if (!config_.dma || rx_dma_channel_ < 0 ||
      !dma_channel_get_irq1_status(rx_dma_channel_)) return;
  dma_channel_acknowledge_irq1(rx_dma_channel_);
  if (!active_ || !hardware_armed_) return;
  reached_limit(false);
}

void Pl022SpiTargetTransport::cs_interrupt(int controller) {
  Pl022SpiTargetTransport* transport = instances_[controller];
  if (transport == null) return;
  uint32_t events = gpio_get_irq_event_mask(transport->config_.cs);
  if ((events & GPIO_IRQ_EDGE_RISE) == 0) return;
  gpio_acknowledge_irq(transport->config_.cs, GPIO_IRQ_EDGE_RISE);
  if (!transport->active_) return;
  if (transport->hardware_armed_) {
    transport->complete(false, true);
  } else if (transport->limit_reached_) {
    transport->active_ = false;
    transport->waiting_for_cs_inactive_ = false;
    transport->client_->target_complete(
        transport->size_, transport->transfer_error_, true);
  } else if (transport->waiting_for_cs_inactive_) {
    transport->waiting_for_cs_inactive_ = false;
    transport->start_hardware(true);
  }
}

void Pl022SpiTargetTransport::abort() {
  uint32_t interrupt_status = save_and_disable_interrupts();
  if (active_) {
    stop_hardware();
    active_ = false;
    waiting_for_cs_inactive_ = false;
    limit_reached_ = false;
    transmit_ = null;
    receive_ = null;
    size_ = 0;
  }
  restore_interrupts(interrupt_status);
}

void Pl022SpiTargetTransport::shutdown() {
  uint32_t interrupt_status = save_and_disable_interrupts();
  if (!initialized_) {
    restore_interrupts(interrupt_status);
    return;
  }
  abort();
  gpio_set_irq_enabled(config_.cs, GPIO_IRQ_EDGE_RISE, false);
  gpio_acknowledge_irq(config_.cs, GPIO_IRQ_EDGE_RISE);
  irq_handler_t handler = config_.controller == 0
      ? cs0_interrupt
      : cs1_interrupt;
  gpio_remove_raw_irq_handler_masked64(1ull << config_.cs, handler);
  spi_deinit(spi());
  instances_[config_.controller] = null;
  if (tx_dma_channel_ >= 0) dma_channel_unclaim(tx_dma_channel_);
  if (rx_dma_channel_ >= 0) dma_channel_unclaim(rx_dma_channel_);
  tx_dma_channel_ = -1;
  rx_dma_channel_ = -1;
  initialized_ = false;
  restore_interrupts(interrupt_status);
}

Rp2350SpiTargetTransport* create_rp2350_spi_target_transport(
    const Rp2350SpiTargetTransportConfig& config,
    Rp2350SpiTargetClient* client) {
  int tx_dma_channel = -1;
  int rx_dma_channel = -1;
  if (config.dma) {
    tx_dma_channel = dma_claim_unused_channel(false);
    if (tx_dma_channel >= 0) rx_dma_channel = dma_claim_unused_channel(false);
    if (rx_dma_channel < 0) {
      if (tx_dma_channel >= 0) dma_channel_unclaim(tx_dma_channel);
      return null;
    }
  }
  auto transport = _new Pl022SpiTargetTransport(
      config, client, tx_dma_channel, rx_dma_channel);
  if (transport == null) {
    if (tx_dma_channel >= 0) dma_channel_unclaim(tx_dma_channel);
    if (rx_dma_channel >= 0) dma_channel_unclaim(rx_dma_channel);
    return null;
  }
  if (!transport->initialize()) {
    delete transport;
    return null;
  }
  return transport;
}

Rp2350SpiEventSource* Rp2350SpiEventSource::instance_ = null;
SpiDevice* volatile
    Rp2350SpiEventSource::active_[kControllerCount] = {};
SpiTargetResourceBase* volatile
    Rp2350SpiEventSource::targets_[kControllerCount] = {};
uint32_t Rp2350SpiEventSource::pending_[kControllerCount] = {};
uint32_t Rp2350SpiEventSource::target_pending_[kControllerCount] = {};
uint32_t Rp2350SpiEventSource::idle_poll_mask_ = 0;

Rp2350SpiEventSource::Rp2350SpiEventSource()
    : Rp2350PeripheralEventSource("RP2350 SPI") {
  ASSERT(instance_ == null);
  instance_ = this;

  irq_set_exclusive_handler(SPI0_IRQ, spi0_interrupt);
  irq_set_exclusive_handler(SPI1_IRQ, spi1_interrupt);
  irq_set_priority(SPI0_IRQ, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_priority(SPI1_IRQ, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_enabled(SPI0_IRQ, false);
  irq_set_enabled(SPI1_IRQ, false);
  irq_add_shared_handler(DMA_IRQ_1, dma_interrupt,
                         PICO_SHARED_IRQ_HANDLER_DEFAULT_ORDER_PRIORITY);
  irq_set_priority(DMA_IRQ_1, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_enabled(DMA_IRQ_1, true);
  Rp2350EventDispatcher::instance()->attach(Rp2350EventDispatcher::SPI, this);
}

Rp2350SpiEventSource::~Rp2350SpiEventSource() {
  irq_set_enabled(SPI0_IRQ, false);
  irq_set_enabled(SPI1_IRQ, false);
  irq_remove_handler(SPI0_IRQ, spi0_interrupt);
  irq_remove_handler(SPI1_IRQ, spi1_interrupt);
  irq_remove_handler(DMA_IRQ_1, dma_interrupt);
  instance_ = null;
  Rp2350EventDispatcher::instance()->detach(Rp2350EventDispatcher::SPI, this);
}

bool Rp2350SpiEventSource::start_operation(SpiDevice* device) {
  Locker locker(mutex());
  int controller = device->controller();
  if (active_[controller] != null) return false;
  active_[controller] = device;
  __atomic_store_n(&pending_[controller], 0, __ATOMIC_RELEASE);
  __atomic_fetch_and(&idle_poll_mask_, ~(1u << controller),
                     __ATOMIC_RELEASE);
  if (device->start_operation_locked()) return true;
  active_[controller] = null;
  return false;
}

FinishStatus Rp2350SpiEventSource::finish_operation(
    SpiDevice* device, uint8_t* destination, uint32_t destination_size,
    uint32_t from, bool read) {
  Locker locker(mutex());
  int controller = device->controller();
  if (active_[controller] != device) return FinishStatus::INVALID_STATE;
  FinishStatus result = device->finish_operation_locked(
      destination, destination_size, from, read);
  if (result == FinishStatus::COMPLETE ||
      result == FinishStatus::HARDWARE_ERROR) {
    clear_operation_locked(controller);
  }
  return result;
}

bool Rp2350SpiEventSource::abort_operation(SpiDevice* device) {
  Locker locker(mutex());
  int controller = device->controller();
  if (active_[controller] != device) return true;
  device->abort_operation_locked();
  clear_operation_locked(controller);
  return true;
}

bool Rp2350SpiEventSource::register_target(SpiTargetResourceBase* target) {
  Locker locker(mutex());
  int controller = target->controller();
  if (targets_[controller] != null || active_[controller] != null) return false;
  targets_[controller] = target;
  __atomic_store_n(&target_pending_[controller], 0, __ATOMIC_RELEASE);
  return true;
}

void Rp2350SpiEventSource::notify_target(
    SpiTargetResourceBase* target, uint32_t state) {
  int controller = target->controller();
  if (targets_[controller] != target) return;
  uint32_t previous = __atomic_fetch_or(
      &target_pending_[controller], state, __ATOMIC_ACQ_REL);
  if ((previous & state) != state) Rp2350EventDispatcher::instance()->wake();
}

void Rp2350SpiEventSource::notify_target_from_isr(
    SpiTargetResourceBase* target, uint32_t state) {
  Rp2350SpiEventSource* source = instance_;
  if (source == null) return;
  int controller = target->controller();
  if (targets_[controller] != target) return;
  uint32_t previous = __atomic_fetch_or(
      &target_pending_[controller], state, __ATOMIC_ACQ_REL);
  if ((previous & state) != state) {
    Rp2350EventDispatcher::instance()->wake_from_isr();
  }
}

void Rp2350SpiEventSource::on_unregister_resource(
    Locker& locker, Resource* resource) {
  USE(locker);
  for (int controller = 0; controller < kControllerCount; controller++) {
    if (targets_[controller] == resource) {
      auto target = targets_[controller];
      target->shutdown_locked();
      targets_[controller] = null;
      __atomic_store_n(&target_pending_[controller], 0, __ATOMIC_RELEASE);
      return;
    }
  }
  auto device = static_cast<SpiDevice*>(resource);
  int controller = device->controller();
  if (active_[controller] != device) return;
  device->abort_operation_locked();
  clear_operation_locked(controller);
}

void Rp2350SpiEventSource::clear_operation_locked(int controller) {
  irq_set_enabled(controller == 0 ? SPI0_IRQ : SPI1_IRQ, false);
  active_[controller] = null;
  __atomic_store_n(&pending_[controller], 0, __ATOMIC_RELEASE);
  __atomic_fetch_and(&idle_poll_mask_, ~(1u << controller),
                     __ATOMIC_RELEASE);
}

void Rp2350SpiEventSource::notify_from_isr(int controller) {
  Rp2350SpiEventSource* source = instance_;
  if (source == null) return;
  __atomic_fetch_and(&idle_poll_mask_, ~(1u << controller),
                     __ATOMIC_RELEASE);
  uint32_t previous = __atomic_exchange_n(
      &pending_[controller], 1, __ATOMIC_ACQ_REL);
  if (previous == 0) Rp2350EventDispatcher::instance()->wake_from_isr();
}

void Rp2350SpiEventSource::request_idle_poll_from_isr(int controller) {
  __atomic_fetch_or(&idle_poll_mask_, 1u << controller,
                    __ATOMIC_RELEASE);
  Rp2350EventDispatcher::instance()->wake_from_isr();
}

void Rp2350SpiEventSource::spi0_interrupt() { interrupt(0); }
void Rp2350SpiEventSource::spi1_interrupt() { interrupt(1); }

void Rp2350SpiEventSource::interrupt(int controller) {
  SpiDevice* device = active_[controller];
  if (device != null) {
    device->handle_interrupt_from_isr();
    return;
  }
  SpiTargetResourceBase* target = targets_[controller];
  if (target != null) target->handle_spi_interrupt_from_isr();
}

void Rp2350SpiEventSource::dma_interrupt() {
  for (int controller = 0; controller < kControllerCount; controller++) {
    SpiTargetResourceBase* target = targets_[controller];
    if (target != null) target->handle_dma_interrupt_from_isr();
  }
}

void Rp2350SpiEventSource::dispatch_pending(const Locker& locker) {
  uint32_t poll_mask = __atomic_exchange_n(
      &idle_poll_mask_, 0, __ATOMIC_ACQ_REL);
  for (int controller = 0; controller < kControllerCount; controller++) {
    SpiDevice* device = active_[controller];
    if (device != null) {
      uint32_t state = __atomic_exchange_n(
          &pending_[controller], 0, __ATOMIC_ACQ_REL);
      if ((poll_mask & (1u << controller)) != 0) {
        if (device->finish_if_idle_locked()) {
          state |= kTransferDoneState;
        } else {
          __atomic_fetch_or(&idle_poll_mask_, 1u << controller,
                            __ATOMIC_RELEASE);
        }
      }
      if (state != 0 && device->operation_complete()) {
        dispatch(locker, device, state);
      }
    }

    SpiTargetResourceBase* target = targets_[controller];
    if (target != null) {
      uint32_t target_state = __atomic_exchange_n(
          &target_pending_[controller], 0, __ATOMIC_ACQ_REL);
      if (target_state != 0) dispatch(locker, target, target_state);
    }
  }
}

bool Rp2350SpiEventSource::poll() {
  Locker locker(mutex());
  dispatch_pending(locker);
  return __atomic_load_n(&idle_poll_mask_, __ATOMIC_ACQUIRE) != 0;
}

EventSource* create_rp2350_spi_event_source() {
  return _new Rp2350SpiEventSource();
}

bool SpiTargetResourceBase::initialize() {
  ASSERT(!initialized_ && transport_ == null);
  Rp2350SpiTargetTransportConfig config = {
    .controller = controller_,
    .mosi = mosi_,
    .miso = miso_,
    .clock = clock_,
    .cs = cs_,
    .mode = mode_,
    .transmit_lsb_first = transmit_lsb_first_,
    .receive_lsb_first = receive_lsb_first_,
    .dma = dma_,
    .complete_at_limit = complete_at_limit_,
  };
  transport_ = create_rp2350_spi_target_transport(config, this);
  if (transport_ == null) return false;
  if (!Rp2350SpiEventSource::instance()->register_target(this)) {
    transport_->shutdown();
    delete transport_;
    transport_ = null;
    return false;
  }
  initialized_ = true;
  return true;
}

void SpiTargetResourceBase::shutdown_locked() {
  if (!initialized_) return;
  transport_->abort();
  transport_->shutdown();
  initialized_ = false;
}

bool SpiTargetResourceBase::arm(
    uint8_t* tx_buffer, uint8_t* rx_buffer,
    uint32_t size, bool from_isr) {
  ASSERT(initialized_ && transport_ != null);
  return transport_->arm(tx_buffer, rx_buffer, size, from_isr);
}

void SpiTargetResourceBase::cancel_arm_from_task() {
  if (initialized_) transport_->abort();
}

bool SpiTargetResource::abort() {
  if (!operation_in_flight_) return false;
  cancel_arm_from_task();
  if (!operation_complete_) {
    transferred_ = 0;
    operation_complete_ = true;
  }
  notify(kTargetDoneState);
  return true;
}

int SpiTargetResource::finish(
    uint8_t* destination, uint32_t destination_size) {
  if (!operation_in_flight_ || !operation_complete_) return -1;
  if (destination_size < receive_size_) return -2;
  if (hardware_error_) {
    clear_operation();
    return -3;
  }
  uint32_t result_size = transferred_ < receive_size_
      ? transferred_
      : receive_size_;
  if (result_size != 0) {
    memcpy(destination, rx_buffer_, result_size);
    if (receive_lsb_first()) {
      for (uint32_t i = 0; i < result_size; i++) {
        destination[i] = reverse_byte(destination[i]);
      }
    }
  }
  clear_operation();
  return static_cast<int>(result_size);
}

bool SpiBufferTargetResource::start() {
  if (running_) return false;
  running_ = true;
  stopping_ = false;
  rearm_failed_ = false;
  if (arm(response_, active_receive_buffer(), size_, false)) return true;
  running_ = false;
  return false;
}

bool SpiBufferTargetResource::request_stop() {
  if (!running_) return false;
  stopping_ = true;
  cancel_arm_from_task();
  running_ = false;
  notify(kBufferTargetStoppedState);
  return true;
}

int SpiBufferTargetResource::get(uint32_t index) const {
  uint32_t status = save_and_disable_interrupts();
  uint8_t result = load_response(index);
  restore_interrupts(status);
  return transmit_lsb_first() ? reverse_byte(result) : result;
}

void SpiBufferTargetResource::set(uint32_t index, uint8_t value) {
  if (transmit_lsb_first()) value = reverse_byte(value);
  uint32_t status = save_and_disable_interrupts();
  store_response(index, value);
  restore_interrupts(status);
}

void SpiBufferTargetResource::read(
    uint32_t index, uint8_t* destination, uint32_t length) const {
  for (uint32_t i = 0; i < length; i++) destination[i] = get(index + i);
}

void SpiBufferTargetResource::write(
    uint32_t index, const uint8_t* source, uint32_t length) {
  for (uint32_t i = 0; i < length; i++) set(index + i, source[i]);
}

int SpiBufferTargetResource::receive(uint8_t* destination) {
  uint32_t status = save_and_disable_interrupts();
  if (receive_count_ == 0) {
    int result = rearm_failed_ ? -2 : (transfer_error_ ? -3 : -1);
    if (result == -3) transfer_error_ = false;
    restore_interrupts(status);
    return result;
  }
  uint32_t queue_index = receive_head_;
  uint32_t buffer_index = receive_indices_[queue_index];
  uint32_t length = receive_lengths_[queue_index];
  restore_interrupts(status);

  const uint8_t* source = receive_storage_ + buffer_index * size_;
  memcpy(destination, source, length);
  if (receive_lsb_first()) {
    for (uint32_t i = 0; i < length; i++) {
      destination[i] = reverse_byte(destination[i]);
    }
  }

  status = save_and_disable_interrupts();
  ASSERT(free_count_ < queue_depth_);
  free_indices_[free_count_++] = buffer_index;
  receive_head_++;
  if (receive_head_ == queue_depth_) receive_head_ = 0;
  receive_count_--;
  restore_interrupts(status);
  return static_cast<int>(length);
}

word SpiBufferTargetResource::dropped_receive_count() const {
  uint32_t status = save_and_disable_interrupts();
  word result = dropped_receive_count_;
  restore_interrupts(status);
  return result;
}

void SpiBufferTargetResource::on_armed(bool from_isr) {
  if (initially_armed_) return;
  initially_armed_ = true;
  if (from_isr) {
    notify_from_isr(kBufferTargetArmedState);
  } else {
    notify(kBufferTargetArmedState);
  }
}

void SpiBufferTargetResource::on_transaction_end(
    uint32_t bytes, bool transfer_error, bool from_isr) {
  if (bytes > size_) bytes = size_;
  bool enqueued = false;
  if (transfer_error) transfer_error_ = true;
  if (!stopping_ && !transfer_error && can_receive_ && bytes != 0) {
    if (free_count_ != 0) {
      uint32_t queue_index = receive_head_ + receive_count_;
      if (queue_index >= queue_depth_) queue_index -= queue_depth_;
      receive_indices_[queue_index] = active_receive_index_;
      receive_lengths_[queue_index] = bytes;
      active_receive_index_ = free_indices_[--free_count_];
      receive_count_++;
      enqueued = true;
    } else if (dropped_receive_count_ != Smi::MAX_SMI_VALUE) {
      dropped_receive_count_++;
    }
  }

  if (stopping_) {
    running_ = false;
    if (from_isr) {
      notify_from_isr(kBufferTargetStoppedState);
    } else {
      notify(kBufferTargetStoppedState);
    }
    return;
  }

  if (!arm(response_, active_receive_buffer(), size_, from_isr)) {
    rearm_failed_ = true;
    running_ = false;
  }
  if (enqueued || rearm_failed_ || transfer_error) {
    if (from_isr) {
      notify_from_isr(kBufferTargetReceivedState);
    } else {
      notify(kBufferTargetReceivedState);
    }
  }
}

void SpiResourceGroup::on_unregister_resource(Resource* resource) {
  auto device = static_cast<SpiDevice*>(resource);
  ASSERT(device_count_ > 0);
  device_count_--;
  if (reserved_device_ == device) reserved_device_ = null;
  ASSERT(active_device_ != device);
}

void SpiDevice::set_interrupts_enabled(bool enabled) {
  irq_set_enabled(controller() == 0 ? SPI0_IRQ : SPI1_IRQ, enabled);
  if (!enabled) spi_get_hw(group_->instance())->imsc = 0;
}

void SpiDevice::fill_fifo() {
  spi_hw_t* hardware = spi_get_hw(group_->instance());
  while (transmitted_ < total_length_ &&
         transmitted_ - received_ < kFifoDepth &&
         (hardware->sr & SPI_SSPSR_TNF_BITS) != 0) {
    hardware->dr = buffer_[transmitted_++];
  }
}

bool SpiDevice::start_operation_locked() {
  ASSERT(buffer_ != null && total_length_ != 0);
  ASSERT(group_->active_device() == null);

  operation_active_ = true;
  operation_complete_ = false;
  hardware_error_ = false;
  transmitted_ = 0;
  received_ = 0;
  group_->set_active_device(this);

  set_interrupts_enabled(false);
  group_->ensure_configuration(frequency_, mode_);
  spi_inst_t* spi = group_->instance();
  spi_hw_t* hardware = spi_get_hw(spi);
  hardware->icr = SPI_SSPICR_RORIC_BITS | SPI_SSPICR_RTIC_BITS;

  if (dc_ >= 0) gpio_put(dc_, dc_value_);
  if (cs_ >= 0) gpio_put(cs_, 0);
  fill_fifo();
  hardware->imsc = SPI_SSPIMSC_TXIM_BITS |
                   SPI_SSPIMSC_RXIM_BITS |
                   SPI_SSPIMSC_RTIM_BITS |
                   SPI_SSPIMSC_RORIM_BITS;
  set_interrupts_enabled(true);
  return true;
}

void SpiDevice::complete_from_isr() {
  spi_get_hw(group_->instance())->imsc = 0;
  if (cs_ >= 0 && !keep_cs_) gpio_put(cs_, 1);
  operation_complete_ = true;
  Rp2350SpiEventSource::notify_from_isr(controller());
}

void SpiDevice::complete_locked() {
  spi_get_hw(group_->instance())->imsc = 0;
  if (cs_ >= 0 && !keep_cs_) gpio_put(cs_, 1);
  operation_complete_ = true;
}

void SpiDevice::handle_interrupt_from_isr() {
  spi_hw_t* hardware = spi_get_hw(group_->instance());
  if (!operation_active_ || operation_complete_) {
    hardware->imsc = 0;
    hardware->icr = SPI_SSPICR_RORIC_BITS | SPI_SSPICR_RTIC_BITS;
    return;
  }

  uint32_t status = hardware->mis;
  if ((status & SPI_SSPMIS_RORMIS_BITS) != 0) {
    hardware->imsc = 0;
    hardware->icr = SPI_SSPICR_RORIC_BITS | SPI_SSPICR_RTIC_BITS;
    hw_clear_bits(&hardware->cr1, SPI_SSPCR1_SSE_BITS);
    group_->invalidate_configuration();
    hardware_error_ = true;
    if (cs_ >= 0) gpio_put(cs_, 1);
    operation_complete_ = true;
    Rp2350SpiEventSource::notify_from_isr(controller());
    return;
  }

  while ((hardware->sr & SPI_SSPSR_RNE_BITS) != 0) {
    uint8_t byte = static_cast<uint8_t>(hardware->dr);
    if (received_ >= total_length_) {
      hardware_error_ = true;
    } else {
      buffer_[received_++] = byte;
    }
  }
  hardware->icr = SPI_SSPICR_RTIC_BITS;

  fill_fifo();
  uint32_t masks = SPI_SSPIMSC_RXIM_BITS |
                   SPI_SSPIMSC_RTIM_BITS |
                   SPI_SSPIMSC_RORIM_BITS;
  if (transmitted_ < total_length_) masks |= SPI_SSPIMSC_TXIM_BITS;
  hardware->imsc = masks;

  if (hardware_error_) {
    hardware->imsc = 0;
    hw_clear_bits(&hardware->cr1, SPI_SSPCR1_SSE_BITS);
    group_->invalidate_configuration();
    if (cs_ >= 0) gpio_put(cs_, 1);
    operation_complete_ = true;
    Rp2350SpiEventSource::notify_from_isr(controller());
  } else if (received_ == total_length_) {
    hardware->imsc = 0;
    if ((hardware->sr & SPI_SSPSR_BSY_BITS) == 0) {
      complete_from_isr();
    } else {
      Rp2350SpiEventSource::request_idle_poll_from_isr(controller());
    }
  }
}

bool SpiDevice::finish_if_idle_locked() {
  if (!operation_active_ || operation_complete_) return operation_complete_;
  if (received_ != total_length_) return false;
  if ((spi_get_hw(group_->instance())->sr & SPI_SSPSR_BSY_BITS) != 0) {
    return false;
  }
  complete_locked();
  return true;
}

FinishStatus SpiDevice::finish_operation_locked(
    uint8_t* destination, uint32_t destination_size,
    uint32_t from, bool read) {
  if (!operation_active_) return FinishStatus::INVALID_STATE;
  if (!operation_complete_) return FinishStatus::PENDING;
  if (from > destination_size || length_ > destination_size - from) {
    return FinishStatus::OUT_OF_BOUNDS;
  }
  if (read && read_ && length_ != 0 && !hardware_error_) {
    memcpy(destination + from, buffer_ + prefix_length_, length_);
  }
  bool hardware_error = hardware_error_;
  cleanup_locked();
  return hardware_error
      ? FinishStatus::HARDWARE_ERROR
      : FinishStatus::COMPLETE;
}

void SpiDevice::abort_operation_locked() {
  if (!operation_active_) return;
  set_interrupts_enabled(false);
  spi_deinit(group_->instance());
  group_->invalidate_configuration();
  if (cs_ >= 0) gpio_put(cs_, 1);
  cleanup_locked();
}

void SpiDevice::cleanup_locked() {
  set_interrupts_enabled(false);
  free(buffer_);
  group_->set_active_device(null);
  clear_operation_fields();
}

void SpiDevice::clear_operation_fields() {
  buffer_ = null;
  prefix_length_ = 0;
  length_ = 0;
  total_length_ = 0;
  transmitted_ = 0;
  received_ = 0;
  read_ = false;
  keep_cs_ = false;
  dc_value_ = 0;
  operation_active_ = false;
  operation_complete_ = false;
  hardware_error_ = false;
}

MODULE_IMPLEMENTATION(spi, MODULE_SPI)

PRIMITIVE(init) {
  ARGS(int, mosi, int, miso, int, clock);
  int controller = pins_to_controller(mosi, miso, clock);
  if (controller < 0) FAIL(INVALID_ARGUMENT);
  if (is_restricted_pin(mosi) || is_restricted_pin(miso) ||
      is_restricted_pin(clock)) FAIL(PERMISSION_DENIED);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Rp2350SpiEventSource* event_source = Rp2350SpiEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);
  if (!reserve_controller(controller)) FAIL(ALREADY_IN_USE);

  bool mosi_owned = false;
  bool miso_owned = false;
  bool clock_owned = false;
  if (mosi >= 0) mosi_owned = gpio_pool_take(mosi);
  if ((mosi < 0 || mosi_owned) && miso >= 0) miso_owned = gpio_pool_take(miso);
  if ((mosi < 0 || mosi_owned) && (miso < 0 || miso_owned)) {
    clock_owned = gpio_pool_take(clock);
  }
  if ((mosi >= 0 && !mosi_owned) || (miso >= 0 && !miso_owned) ||
      !clock_owned) {
    if (clock_owned) gpio_pool_put(clock);
    if (miso_owned) gpio_pool_put(miso);
    if (mosi_owned) gpio_pool_put(mosi);
    release_controller(controller);
    FAIL(ALREADY_IN_USE);
  }

  SpiResourceGroup* group = _new SpiResourceGroup(
      process, event_source, controller, mosi, miso, clock);
  if (group == null) {
    gpio_pool_put(clock);
    if (miso_owned) gpio_pool_put(miso);
    if (mosi_owned) gpio_pool_put(mosi);
    release_controller(controller);
    FAIL(MALLOC_FAILED);
  }

  group->ensure_configuration(1000000, 0);
  if (mosi >= 0) gpio_set_function(mosi, GPIO_FUNC_SPI);
  if (miso >= 0) gpio_set_function(miso, GPIO_FUNC_SPI);
  gpio_set_function(clock, GPIO_FUNC_SPI);
  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(close) {
  ARGS(SpiResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(device) {
  ARGS(SpiResourceGroup, group, int, cs, int, dc, int, command_bits,
       int, address_bits, int, frequency, int, mode,
       int, cs_setup_cycles, int, cs_hold_cycles);
  if (cs_setup_cycles != 0 || cs_hold_cycles != 0) FAIL(UNIMPLEMENTED);
  if (command_bits < 0 || command_bits > 16 ||
      address_bits < 0 || address_bits > 64 ||
      ((command_bits + address_bits) & 7) != 0 ||
      mode < 0 || mode > 3 || frequency <= 0 ||
      !frequency_is_supported(static_cast<uint32_t>(frequency))) {
    FAIL(INVALID_ARGUMENT);
  }
  if (cs < -1 || dc < -1 || (cs >= 0 && !is_valid_pin(cs)) ||
      (dc >= 0 && !is_valid_pin(dc))) FAIL(INVALID_ARGUMENT);
  if (is_restricted_pin(cs) || is_restricted_pin(dc)) {
    FAIL(PERMISSION_DENIED);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  bool cs_owned = cs < 0 || gpio_pool_take(cs);
  bool dc_owned = false;
  if (cs_owned) dc_owned = dc < 0 || gpio_pool_take(dc);
  if (!cs_owned || !dc_owned) {
    if (cs >= 0 && cs_owned) gpio_pool_put(cs);
    FAIL(ALREADY_IN_USE);
  }

  SpiDevice* device = _new SpiDevice(
      group, cs, dc, static_cast<uint32_t>(frequency),
      static_cast<uint8_t>(mode), static_cast<uint8_t>(command_bits),
      static_cast<uint8_t>(address_bits));
  if (device == null) {
    if (dc >= 0) gpio_pool_put(dc);
    if (cs >= 0) gpio_pool_put(cs);
    FAIL(MALLOC_FAILED);
  }

  if (cs >= 0) {
    gpio_init(cs);
    gpio_disable_pulls(cs);
    gpio_put(cs, 1);
    gpio_set_dir(cs, GPIO_OUT);
  }
  if (dc >= 0) {
    gpio_init(dc);
    gpio_disable_pulls(dc);
    gpio_put(dc, 0);
    gpio_set_dir(dc, GPIO_OUT);
  }

  group->register_resource(device);
  proxy->set_external_address(device);
  return proxy;
}

PRIMITIVE(device_close) {
  ARGS(SpiResourceGroup, group, SpiDevice, device);
  group->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}

static void append_bits(uint8_t* output, uint32_t* offset,
                        uint64_t value, int bit_count) {
  for (int source_bit = bit_count - 1; source_bit >= 0; source_bit--) {
    uint32_t target_bit = *offset;
    if (((value >> source_bit) & 1) != 0) {
      output[target_bit >> 3] |= 1 << (7 - (target_bit & 7));
    }
    (*offset)++;
  }
}

PRIMITIVE(transfer_start) {
  ARGS(SpiDevice, device, Blob, tx, int, command, int64, address,
       int, from, int, to, bool, read, int, dc, bool, keep_cs_active);
  SpiResourceGroup* group = device->group();
  if (group->reserved_device() != null &&
      group->reserved_device() != device) FAIL(INVALID_STATE);
  if (keep_cs_active && group->reserved_device() != device) {
    FAIL(INVALID_STATE);
  }
  if (from < 0 || from > to || to > tx.length()) FAIL(OUT_OF_BOUNDS);

  uint32_t length = static_cast<uint32_t>(to - from);
  uint32_t prefix_length =
      static_cast<uint32_t>(device->command_bits() + device->address_bits()) / 8;
  if (length > UINT32_MAX - prefix_length) FAIL(OUT_OF_RANGE);
  uint32_t total_length = prefix_length + length;
  if (total_length == 0) FAIL(INVALID_ARGUMENT);

  uint8_t* buffer = unvoid_cast<uint8_t*>(malloc(total_length));
  if (buffer == null) FAIL(MALLOC_FAILED);
  memset(buffer, 0, prefix_length);
  uint32_t offset = 0;
  append_bits(buffer, &offset, static_cast<uint32_t>(command),
              device->command_bits());
  append_bits(buffer, &offset, static_cast<uint64_t>(address),
              device->address_bits());
  memcpy(buffer + prefix_length, tx.address() + from, length);

  device->set_dc_value(dc);
  device->prepare_operation(buffer, prefix_length, length, read,
                            keep_cs_active);
  if (!Rp2350SpiEventSource::instance()->start_operation(device)) {
    device->abandon_prepared_operation();
    FAIL(ALREADY_IN_USE);
  }
  return process->null_object();
}

PRIMITIVE(transfer_finish) {
  ARGS(SpiDevice, device, MutableBlob, output, int, from, bool, read);
  if (from < 0) FAIL(OUT_OF_BOUNDS);
  FinishStatus status = Rp2350SpiEventSource::instance()->finish_operation(
      device, output.address(), output.length(), static_cast<uint32_t>(from),
      read);
  if (status == FinishStatus::PENDING) return process->false_object();
  if (status == FinishStatus::INVALID_STATE) FAIL(INVALID_STATE);
  if (status == FinishStatus::OUT_OF_BOUNDS) FAIL(OUT_OF_BOUNDS);
  if (status == FinishStatus::HARDWARE_ERROR) FAIL(HARDWARE_ERROR);
  return process->true_object();
}

PRIMITIVE(transfer_abort) {
  ARGS(SpiDevice, device);
  return BOOL(Rp2350SpiEventSource::instance()->abort_operation(device));
}

PRIMITIVE(acquire_bus) {
  ARGS(SpiDevice, device);
  SpiResourceGroup* group = device->group();
  if (group->active_device() != null || group->reserved_device() != null) {
    return process->false_object();
  }
  group->set_reserved_device(device);
  return process->true_object();
}

PRIMITIVE(release_bus) {
  ARGS(SpiDevice, device);
  SpiResourceGroup* group = device->group();
  if (group->reserved_device() != device || group->active_device() != null) {
    FAIL(INVALID_STATE);
  }
  group->set_reserved_device(null);
  if (device->cs() >= 0) gpio_put(device->cs(), 1);
  return process->null_object();
}

PRIMITIVE(target_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  Rp2350SpiEventSource* event_source = Rp2350SpiEventSource::instance();
  if (event_source == null) FAIL(ALREADY_CLOSED);
  auto group = _new SpiTargetResourceGroup(process, event_source);
  if (group == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}

static bool reserve_target_pins(
    int mosi, int miso, int clock, int cs,
    bool* mosi_owned, bool* miso_owned,
    bool* clock_owned, bool* cs_owned) {
  *mosi_owned = mosi < 0 || gpio_pool_take(mosi);
  *miso_owned = *mosi_owned && (miso < 0 || gpio_pool_take(miso));
  *clock_owned = *miso_owned && gpio_pool_take(clock);
  *cs_owned = *clock_owned && gpio_pool_take(cs);
  return *cs_owned;
}

static void release_target_pins(
    int mosi, int miso, int clock, int cs,
    bool mosi_owned, bool miso_owned,
    bool clock_owned, bool cs_owned) {
  if (cs_owned) gpio_pool_put(cs);
  if (clock_owned) gpio_pool_put(clock);
  if (miso >= 0 && miso_owned) gpio_pool_put(miso);
  if (mosi >= 0 && mosi_owned) gpio_pool_put(mosi);
}

PRIMITIVE(target_create) {
  ARGS(SpiTargetResourceGroup, group,
       int, mosi, int, miso, int, clock, int, cs,
       int, mode, bool, transmit_lsb_first, bool, receive_lsb_first,
       uint32, max_transfer_size, bool, dma);
  int controller = target_pins_to_controller(mosi, miso, clock, cs);
  if (controller < 0 || mode < 0 || mode > 3 || (mode & 1) == 0 ||
      max_transfer_size == 0 || max_transfer_size > kTargetMaximum ||
      (!dma && max_transfer_size > kTargetNonDmaMaximum)) {
    FAIL(INVALID_ARGUMENT);
  }
  if (is_restricted_pin(mosi) || is_restricted_pin(miso) ||
      is_restricted_pin(clock) || is_restricted_pin(cs)) {
    FAIL(PERMISSION_DENIED);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  if (!reserve_controller(controller)) FAIL(ALREADY_IN_USE);

  bool mosi_owned = false;
  bool miso_owned = false;
  bool clock_owned = false;
  bool cs_owned = false;
  if (!reserve_target_pins(mosi, miso, clock, cs,
                           &mosi_owned, &miso_owned,
                           &clock_owned, &cs_owned)) {
    release_target_pins(mosi, miso, clock, cs,
                        mosi_owned, miso_owned, clock_owned, cs_owned);
    release_controller(controller);
    FAIL(ALREADY_IN_USE);
  }

  auto target = _new SpiTargetResource(
      group, controller, mosi, miso, clock, cs,
      static_cast<uint8_t>(mode), transmit_lsb_first, receive_lsb_first,
      dma, max_transfer_size);
  if (target == null) {
    release_target_pins(mosi, miso, clock, cs,
                        mosi_owned, miso_owned, clock_owned, cs_owned);
    release_controller(controller);
    FAIL(MALLOC_FAILED);
  }
  if (!target->initialize()) {
    delete target;
    FAIL(ALREADY_IN_USE);
  }
  group->register_resource(target);
  proxy->set_external_address(target);
  return proxy;
}

PRIMITIVE(target_close) {
  ARGS(SpiTargetResourceGroup, group, SpiTargetResource, target);
  if (target->operation_in_flight()) FAIL(INVALID_STATE);
  group->unregister_resource(target);
  target_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(target_transfer_start) {
  ARGS(SpiTargetResource, target, Blob, transmit,
       uint32, receive_size, uint8, fill_byte);
  if (target->operation_in_flight()) FAIL(INVALID_STATE);
  uint32_t transmit_size = transmit.length();
  uint32_t transfer_size = transmit_size > receive_size
      ? transmit_size
      : receive_size;
  if (transfer_size == 0 || transfer_size > target->max_transfer_size()) {
    FAIL(INVALID_ARGUMENT);
  }
  uint8_t* tx_buffer = unvoid_cast<uint8_t*>(malloc(transfer_size));
  uint8_t* rx_buffer = unvoid_cast<uint8_t*>(malloc(transfer_size));
  if (tx_buffer == null || rx_buffer == null) {
    free(tx_buffer);
    free(rx_buffer);
    FAIL(MALLOC_FAILED);
  }
  memset(tx_buffer, fill_byte, transfer_size);
  memcpy(tx_buffer, transmit.address(), transmit_size);
  if (target->transmit_lsb_first()) {
    for (uint32_t i = 0; i < transfer_size; i++) {
      tx_buffer[i] = reverse_byte(tx_buffer[i]);
    }
  }
  if (!target->start(
          tx_buffer, rx_buffer, receive_size, transfer_size)) {
    FAIL(INVALID_STATE);
  }
  return process->null_object();
}

PRIMITIVE(target_transfer_finish) {
  ARGS(SpiTargetResource, target, MutableBlob, receive_buffer, bool, abort);
  if (!target->operation_in_flight()) FAIL(INVALID_STATE);
  if (abort) return BOOL(target->abort());
  int result = target->finish(
      receive_buffer.address(), receive_buffer.length());
  if (result == -1) FAIL(INVALID_STATE);
  if (result == -2) FAIL(OUT_OF_BOUNDS);
  if (result == -3) return Smi::from(-1);
  return Smi::from(result);
}

PRIMITIVE(buffer_target_create) {
  ARGS(SpiTargetResourceGroup, group,
       int, mosi, int, miso, int, clock, int, cs,
       int, mode, bool, transmit_lsb_first, bool, receive_lsb_first,
       uint32, receive_queue_depth, Blob, response, bool, dma);
  uint32_t size = response.length();
  int controller = target_pins_to_controller(mosi, miso, clock, cs);
  if (controller < 0 || mode < 0 || mode > 3 || (mode & 1) == 0 ||
      size == 0 || size > kTargetMaximum || receive_queue_depth == 0 ||
      receive_queue_depth == UINT32_MAX ||
      (!dma && size > kTargetNonDmaMaximum)) {
    FAIL(INVALID_ARGUMENT);
  }
  if (is_restricted_pin(mosi) || is_restricted_pin(miso) ||
      is_restricted_pin(clock) || is_restricted_pin(cs)) {
    FAIL(PERMISSION_DENIED);
  }
  uint32_t receive_buffer_count = receive_queue_depth + 1;
  if (size > SIZE_MAX / receive_buffer_count ||
      receive_queue_depth > SIZE_MAX / sizeof(uint32_t)) {
    FAIL(INVALID_ARGUMENT);
  }

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);
  if (!reserve_controller(controller)) FAIL(ALREADY_IN_USE);

  bool mosi_owned = false;
  bool miso_owned = false;
  bool clock_owned = false;
  bool cs_owned = false;
  if (!reserve_target_pins(mosi, miso, clock, cs,
                           &mosi_owned, &miso_owned,
                           &clock_owned, &cs_owned)) {
    release_target_pins(mosi, miso, clock, cs,
                        mosi_owned, miso_owned, clock_owned, cs_owned);
    release_controller(controller);
    FAIL(ALREADY_IN_USE);
  }

  uint8_t* response_buffer = unvoid_cast<uint8_t*>(malloc(size));
  uint8_t* receive_storage = unvoid_cast<uint8_t*>(
      malloc(static_cast<size_t>(size) * receive_buffer_count));
  uint32_t* receive_indices = unvoid_cast<uint32_t*>(
      malloc(receive_queue_depth * sizeof(uint32_t)));
  uint32_t* receive_lengths = unvoid_cast<uint32_t*>(
      malloc(receive_queue_depth * sizeof(uint32_t)));
  uint32_t* free_indices = unvoid_cast<uint32_t*>(
      malloc(receive_queue_depth * sizeof(uint32_t)));
  if (response_buffer == null || receive_storage == null ||
      receive_indices == null || receive_lengths == null ||
      free_indices == null) {
    free(response_buffer);
    free(receive_storage);
    free(receive_indices);
    free(receive_lengths);
    free(free_indices);
    release_target_pins(mosi, miso, clock, cs,
                        mosi_owned, miso_owned, clock_owned, cs_owned);
    release_controller(controller);
    FAIL(MALLOC_FAILED);
  }
  memcpy(response_buffer, response.address(), size);
  if (transmit_lsb_first) {
    for (uint32_t i = 0; i < size; i++) {
      response_buffer[i] = reverse_byte(response_buffer[i]);
    }
  }

  auto target = _new SpiBufferTargetResource(
      group, controller, mosi, miso, clock, cs,
      static_cast<uint8_t>(mode), transmit_lsb_first, receive_lsb_first,
      dma, response_buffer, receive_storage,
      receive_indices, receive_lengths, free_indices,
      size, receive_queue_depth, mosi >= 0, miso >= 0);
  if (target == null) {
    free(response_buffer);
    free(receive_storage);
    free(receive_indices);
    free(receive_lengths);
    free(free_indices);
    release_target_pins(mosi, miso, clock, cs,
                        mosi_owned, miso_owned, clock_owned, cs_owned);
    release_controller(controller);
    FAIL(MALLOC_FAILED);
  }
  if (!target->initialize()) {
    delete target;
    FAIL(ALREADY_IN_USE);
  }
  group->register_resource(target);
  proxy->set_external_address(target);
  return proxy;
}

PRIMITIVE(buffer_target_arm) {
  ARGS(SpiBufferTargetResource, target);
  if (!target->start()) FAIL(INVALID_STATE);
  return process->null_object();
}

PRIMITIVE(buffer_target_close) {
  ARGS(SpiTargetResourceGroup, group,
       SpiBufferTargetResource, target, bool, abort);
  if (abort) return BOOL(target->request_stop());
  group->unregister_resource(target);
  target_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(buffer_target_get) {
  ARGS(SpiBufferTargetResource, target, uint32, index);
  if (!target->can_transmit()) FAIL(INVALID_STATE);
  if (index >= target->size()) FAIL(OUT_OF_BOUNDS);
  return Smi::from(target->get(index));
}

PRIMITIVE(buffer_target_set) {
  ARGS(SpiBufferTargetResource, target, uint32, index, uint8, value);
  if (!target->can_transmit()) FAIL(INVALID_STATE);
  if (index >= target->size()) FAIL(OUT_OF_BOUNDS);
  target->set(index, value);
  return Smi::from(value);
}

PRIMITIVE(buffer_target_read) {
  ARGS(SpiBufferTargetResource, target,
       uint32, index, MutableBlob, result);
  if (!target->can_transmit()) FAIL(INVALID_STATE);
  uint32_t result_length = static_cast<uint32_t>(result.length());
  if (index > target->size() || result_length > target->size() - index) {
    FAIL(OUT_OF_BOUNDS);
  }
  target->read(index, result.address(), result.length());
  return process->null_object();
}

PRIMITIVE(buffer_target_write) {
  ARGS(SpiBufferTargetResource, target, uint32, index, Blob, bytes);
  if (!target->can_transmit()) FAIL(INVALID_STATE);
  uint32_t byte_count = static_cast<uint32_t>(bytes.length());
  if (index > target->size() || byte_count > target->size() - index) {
    FAIL(OUT_OF_BOUNDS);
  }
  target->write(index, bytes.address(), bytes.length());
  return process->null_object();
}

PRIMITIVE(buffer_target_receive) {
  ARGS(SpiBufferTargetResource, target, MutableBlob, result);
  if (!target->can_receive()) FAIL(INVALID_STATE);
  if (static_cast<uint32_t>(result.length()) < target->size()) {
    FAIL(OUT_OF_BOUNDS);
  }
  int received = target->receive(result.address());
  if (received == -2) FAIL(INVALID_STATE);
  if (received == -3) FAIL(HARDWARE_ERROR);
  return Smi::from(received);
}

PRIMITIVE(buffer_target_dropped_receive_count) {
  ARGS(SpiBufferTargetResource, target);
  return Smi::from(target->dropped_receive_count());
}

}  // namespace toit

#endif  // TOIT_RP2350
