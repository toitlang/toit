// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_RP2350
#include "hardware/clocks.h"
#include "hardware/dma.h"
#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/pio.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../event_sources/event_rp2350.h"
#include "../event_sources/pio_rp2350.h"

namespace toit {
bool gpio_pool_take(int pin);
void gpio_pool_put(int pin);
bool is_restricted_pin(int pin);

static uint32_t get32(const uint8_t* bytes) {
  return uint32_t(bytes[0]) | uint32_t(bytes[1]) << 8 |
      uint32_t(bytes[2]) << 16 | uint32_t(bytes[3]) << 24;
}

// Instructions are shared only within a block with an identical GPIO base.
// At most twelve programs can be live because each has a state-machine user.
struct LoadedProgram {
  uint16_t code[32];
  pio_program_t program = {};
  PIO pio = null;
  int offset = 0;
  int users = 0;
};
static LoadedProgram programs[NUM_PIOS * NUM_PIO_STATE_MACHINES];
static uint32_t irq_claims[NUM_PIOS] = {};

struct PioTransfer {
  uint8_t* data = null;
  int size = 0;
  int channel = -1;
  // 0 pending, 1 complete, 2 cancelled, 3 hardware failure.
  int status = 0;
  int transferred = 0;
  bool receive = false;
  bool cancelling = false;
  bool notified = false;

  bool idle() const {
    return channel < 0 ||
        (!(dma_hw->abort & (1u << channel)) && !dma_channel_is_busy(channel));
  }
  void cancel() {
    if (channel < 0 || status || cancelling) return;
    cancelling = true;
    dma_channel_set_irq0_enabled(channel, false);
    // No SDK abort helper: it spins until the abort completes. The dispatcher
    // observes completion before publishing cancellation or freeing memory.
    hw_clear_bits(&dma_channel_hw_addr(channel)->ctrl_trig, DMA_CH0_CTRL_TRIG_EN_BITS);
    dma_hw->abort = 1u << channel;
  }
  int progress() const {
    auto hw = dma_channel_hw_addr(channel);
    uintptr_t address = receive ? hw->write_addr : hw->read_addr;
    uintptr_t base = reinterpret_cast<uintptr_t>(data);
    return address >= base && address - base <= static_cast<uintptr_t>(size)
        ? static_cast<int>(address - base) : 0;
  }
  void finish() {
    if (channel < 0 || status || !idle()) return;
    auto hw = dma_channel_hw_addr(channel);
    transferred = progress();
    status = cancelling ? 2 : ((hw->ctrl_trig & DMA_CH0_CTRL_TRIG_AHB_ERROR_BITS) ? 3 : 1);
    dma_channel_set_irq0_enabled(channel, false);
    dma_channel_acknowledge_irq0(channel);
  }
  void release() {
    ASSERT(idle());
    if (channel >= 0) {
      dma_channel_set_irq0_enabled(channel, false);
      dma_channel_acknowledge_irq0(channel);
      dma_channel_unclaim(channel);
    }
    free(data);
    *this = PioTransfer();
  }
};

class PioResource : public Resource {
 public:
  TAG(PioResource);
  PioResource(ResourceGroup* group, LoadedProgram* loaded, int sm,
              pio_sm_config config, uint64_t pins, uint64_t outputs,
              uint64_t highs, int entry, uint8_t irqs)
      : Resource(group), loaded_(loaded), sm_(sm), config_(config), pins_(pins),
        outputs_(outputs), highs_(highs), entry_(entry), irqs_(irqs) {}
  ~PioResource() override;
  void delete_or_mark_for_deletion() override;
  void reset();
  void stop() {
    pio_sm_set_enabled(pio(), sm_, false);
    for (auto& t : transfers_) t.cancel();
  }
  bool idle() const { return transfers_[0].idle() && transfers_[1].idle(); }
  PIO pio() const { return loaded_->pio; }
  LoadedProgram* loaded_;
  int sm_;
  pio_sm_config config_;
  uint64_t pins_;
  uint64_t outputs_;
  uint64_t highs_;
  int entry_;
  uint8_t irqs_;
  PioTransfer transfers_[2];
  PioResource* retired_next_ = null;
};

class PioEventSource : public Rp2350PeripheralEventSource {
 public:
  PioEventSource();
  ~PioEventSource() override;
  bool poll() override;
  void retire(PioResource* resource) {
    Locker locker(mutex());
    resource->stop();
    // A retired resource may outlive its process heap. Detach its notifier now.
    delete resource->object_notifier();
    resource->set_object_notifier(null);
    if (resource->idle()) { delete resource; return; }
    resource->retired_next_ = retired_;
    retired_ = resource;
    Rp2350EventDispatcher::instance()->wake();
  }
  static PioEventSource* instance;
  static void interrupt();
 private:
  PioResource* retired_ = null;
};
PioEventSource* PioEventSource::instance = null;
// Mask is read in ISR context; no heap or Resource pointers cross that boundary.
static uint32_t dma_channels = 0;

class PioResourceGroup : public ResourceGroup {
 public:
  TAG(PioResourceGroup);
  PioResourceGroup(Process* process, EventSource* source) : ResourceGroup(process, source) {}
  uint32_t on_event(Resource*, word data, uint32_t state) override { return state | data; }
};

PioEventSource::PioEventSource() : Rp2350PeripheralEventSource("RP2350 PIO") {
  instance = this;
  irq_add_shared_handler(DMA_IRQ_0, interrupt, PICO_SHARED_IRQ_HANDLER_DEFAULT_ORDER_PRIORITY);
  irq_set_priority(DMA_IRQ_0, configMAX_SYSCALL_INTERRUPT_PRIORITY);
  irq_set_enabled(DMA_IRQ_0, true);
  for (int i = 0; i < static_cast<int>(NUM_PIOS); i++) {
    int irq = PIO0_IRQ_0 + 2 * i;
    irq_set_exclusive_handler(irq, interrupt);
    irq_set_priority(irq, configMAX_SYSCALL_INTERRUPT_PRIORITY);
    irq_set_enabled(irq, true);
  }
  Rp2350EventDispatcher::instance()->attach(Rp2350EventDispatcher::PIO, this);
}
PioEventSource::~PioEventSource() {
  // Process teardown has requested cancellation for every retired machine.
  // Dispatcher remains alive until detach has waited for its last poll.
  Rp2350EventDispatcher::instance()->detach(Rp2350EventDispatcher::PIO, this);
  irq_remove_handler(DMA_IRQ_0, interrupt);
  for (int i = 0; i < static_cast<int>(NUM_PIOS); i++) irq_remove_handler(PIO0_IRQ_0 + 2 * i, interrupt);
  while (retired_) {
    auto resource = retired_;
    retired_ = resource->retired_next_;
    // Shutdown runs outside primitives; wait for bounded bus transactions.
    while (!resource->idle()) tight_loop_contents();
    delete resource;
  }
  instance = null;
}
void PioEventSource::interrupt() {
  bool pending = false;
  uint32_t channels = __atomic_load_n(&dma_channels, __ATOMIC_ACQUIRE);
  uint32_t done = dma_hw->ints0 & channels;
  if (done) {
    hw_clear_bits(&dma_hw->inte0, done);
    dma_hw->ints0 = done;
    pending = true;
  }
  for (int i = 0; i < static_cast<int>(NUM_PIOS); i++) {
    PIO pio = pio_get_instance(i);
    uint32_t flags = pio->ints0 & (__atomic_load_n(&irq_claims[i], __ATOMIC_ACQUIRE) << 8);
    if (flags) {
      hw_clear_bits(&pio->inte0, flags);
      pending = true;
    }
  }
  if (pending) Rp2350EventDispatcher::instance()->wake_from_isr();
}
bool PioEventSource::poll() {
  Locker locker(mutex());
  bool polling = false;
  for (auto base : resources()) {
    auto resource = static_cast<PioResource*>(base);
    uint32_t events = 0;
    for (int d = 0; d < 2; d++) {
      auto& t = resource->transfers_[d];
      t.finish();
      polling |= t.channel >= 0 && t.status == 0;
      if (t.status && !t.notified) { events |= 1u << d; t.notified = true; }
    }
    events |= (resource->pio()->irq & resource->irqs_) << 8;
    if (events) dispatch(locker, resource, events);
  }
  auto link = &retired_;
  while (*link) {
    auto resource = *link;
    if (resource->idle()) {
      *link = resource->retired_next_;
      delete resource;
    } else {
      polling = true;
      link = &resource->retired_next_;
    }
  }
  return polling;
}
EventSource* create_rp2350_pio_event_source() { return _new PioEventSource(); }
void PioResource::delete_or_mark_for_deletion() { PioEventSource::instance->retire(this); }
PioResource::~PioResource() {
  for (auto& t : transfers_) {
    if (t.channel >= 0) __atomic_fetch_and(&dma_channels, ~(1u << t.channel), __ATOMIC_ACQ_REL);
    t.release();
  }
  hw_clear_bits(&pio()->inte0, uint32_t(irqs_) << 8);
  pio()->irq = irqs_;
  __atomic_fetch_and(&irq_claims[pio_get_index(pio())], ~uint32_t(irqs_), __ATOMIC_ACQ_REL);
  for (int pin = 0; pin < static_cast<int>(NUM_BANK0_GPIOS); pin++) {
    if (!(pins_ & (uint64_t(1) << pin))) continue;
    gpio_deinit(pin);
    gpio_disable_pulls(pin);
    gpio_set_input_enabled(pin, false);
    gpio_pool_put(pin);
  }
  pio_sm_unclaim(pio(), sm_);
  if (--loaded_->users == 0) {
    pio_remove_program(pio(), &loaded_->program, loaded_->offset);
  }
}
void PioResource::reset() {
  pio_sm_set_enabled(pio(), sm_, false);
  pio_sm_init(pio(), sm_, loaded_->offset + entry_, &config_);
  pio_sm_exec(pio(), sm_, pio_encode_set(pio_x, 0));
  pio_sm_exec(pio(), sm_, pio_encode_set(pio_y, 0));
  pio_sm_exec(pio(), sm_, pio_encode_mov(pio_isr, pio_null));
  pio_sm_exec(pio(), sm_, pio_encode_mov(pio_osr, pio_null));
  pio_sm_restart(pio(), sm_);
  pio_sm_set_pins_with_mask64(pio(), sm_, highs_, pins_);
  pio_sm_set_pindirs_with_mask64(pio(), sm_, outputs_, pins_);
  pio_sm_clkdiv_restart(pio(), sm_);
  pio()->irq = irqs_;
  hw_set_bits(&pio()->inte0, uint32_t(irqs_) << 8);
}

MODULE_IMPLEMENTATION(pio, MODULE_PIO)
PRIMITIVE(init) {
  if (!PioEventSource::instance) FAIL(UNIMPLEMENTED);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new PioResourceGroup(process, PioEventSource::instance);
  if (!group) FAIL(MALLOC_FAILED);
  proxy->set_external_address(group);
  return proxy;
}
PRIMITIVE(create) {
  ARGS(PioResourceGroup, group, Blob, code, Blob, config);
  if (code.length() < 2 || code.length() > 64 || code.length() % 2 || config.length() != 35 * 4) FAIL(INVALID_ARGUMENT);
  int32_t c[35];
  for (int i = 0; i < 35; i++) c[i] = static_cast<int32_t>(get32(config.address() + i * 4));
  int length = code.length() / 2;
  if (c[0] < -1 || c[0] > 32 - length || c[1] < 0 || c[1] > static_cast<int>(PICO_PIO_VERSION) ||
      c[2] < 0 || c[2] > 7 || c[3] < 0 || c[4] < c[3] || c[4] >= length ||
      c[5] < 0 || c[6] < 0 || c[6] > 1 || c[5] + c[6] > 5 || c[7] < 0 || c[7] > 1 ||
      c[8] < 0 || c[8] > 32 || c[9] < 0 || c[9] > 32 || c[10] < 0 || c[10] > 5 ||
      c[11] < 0 || c[11] > 1 || c[12] < 0 || c[12] > 1 ||
      c[13] < 0 || c[13] > 1 || c[14] < 0 || c[14] > 1 ||
      c[15] < 1 || c[15] > 32 || c[16] < 1 || c[16] > 32 ||
      (c[17] != 0 && c[17] != 1 && c[17] != 2 && c[17] != 4 && c[17] != 8 && c[17] != 12) ||
      c[18] < 256 || c[18] > 65536 * 256 || c[19] < 0 || c[19] > 2 || c[20] < 0 || c[20] > 31 ||
      c[21] < 0 || c[21] >= length || c[22] < 0 || c[34] < 0 || c[34] > 15) FAIL(INVALID_ARGUMENT);
  uint64_t pins = uint32_t(c[28]) | uint64_t(uint32_t(c[29])) << 32;
  uint64_t outputs = uint32_t(c[30]) | uint64_t(uint32_t(c[31])) << 32;
  uint64_t highs = uint32_t(c[32]) | uint64_t(uint32_t(c[33])) << 32;
  if ((pins >> NUM_BANK0_GPIOS) || (outputs & ~pins) || (highs & ~outputs)) FAIL(INVALID_ARGUMENT);
  uint16_t instructions[32];
  for (int i = 0; i < length; i++) {
    instructions[i] = code.address()[2*i] | uint16_t(code.address()[2*i+1]) << 8;
    if ((instructions[i] >> 13) == 0 && (instructions[i] & 31) >= length) FAIL(INVALID_ARGUMENT);
    if ((instructions[i] & 0xe060) == 0x2000) {
      int pin = instructions[i] & 31;
      if (pin < 16 && (c[2] & 4)) pin += 32;
      if (!(pins & (uint64_t(1) << pin))) FAIL(INVALID_ARGUMENT);
    }
  }
  int counts[4] = {c[8], c[9], c[10], c[5]};
  for (int i = 0; i < 4; i++) {
    int pin = c[23+i], count = counts[i];
    if (count == 0) { if (pin != -1) FAIL(INVALID_ARGUMENT); continue; }
    if (pin < 0 || pin + count > static_cast<int>(NUM_BANK0_GPIOS)) FAIL(INVALID_ARGUMENT);
    uint64_t mask = ((uint64_t(1) << count) - 1) << pin;
    if (mask & ~pins) FAIL(INVALID_ARGUMENT);
  }
  if (c[27] < -1 || c[27] >= static_cast<int>(NUM_BANK0_GPIOS) ||
      (c[27] >= 0 && !(pins & (uint64_t(1) << c[27])))) FAIL(INVALID_ARGUMENT);
  int ranges = c[2] | ((pins & 0xffff) ? 1 : 0) | ((pins >> 32) ? 4 : 0);
  if ((ranges & 5) == 5) FAIL(INVALID_ARGUMENT);
  uint32_t divider = c[18];
  if (c[22]) {
    uint64_t scaled = uint64_t(clock_get_hz(clk_sys)) * 256;
    uint64_t rounded = (scaled + c[22] / 2) / c[22];
    if (rounded < 256 || rounded > 65536 * 256) FAIL(OUT_OF_RANGE);
    divider = rounded;
  }
  auto proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  Locker locker(PioEventSource::instance->mutex());
  uint64_t reserved = 0;
  for (int pin = 0; pin < static_cast<int>(NUM_BANK0_GPIOS); pin++) {
    if (!(pins & (uint64_t(1) << pin))) continue;
    if (is_restricted_pin(pin) || !gpio_pool_take(pin)) {
      for (int p = 0; p < pin; p++) if (reserved & (uint64_t(1) << p)) gpio_pool_put(p);
      FAIL(ALREADY_IN_USE);
    }
    reserved |= uint64_t(1) << pin;
  }
  LoadedProgram* loaded = null;
  int sm = -1;
  for (int block = 0; block < static_cast<int>(NUM_PIOS) && !loaded; block++) {
    PIO pio = pio_get_instance(block);
    if (__atomic_load_n(&irq_claims[block], __ATOMIC_ACQUIRE) & c[34]) continue;
    bool used = false;
    for (int i = 0; i < 4; i++) used |= pio_sm_is_claimed(pio, i);
    int base = pio_get_gpio_base(pio);
    if (!used) { base = (ranges & 4) ? 16 : 0; pio_set_gpio_base(pio, base); }
    if ((base && (ranges & 1)) || (!base && (ranges & 4))) continue;
    sm = pio_claim_unused_sm(pio, false);
    if (sm < 0) continue;
    for (auto& p : programs) {
      if (p.users && p.pio == pio && p.program.length == length &&
          p.program.origin == c[0] && p.program.pio_version == c[1] &&
          p.program.used_gpio_ranges == c[2] && !memcmp(p.code, instructions, length * 2)) {
        loaded = &p; break;
      }
    }
    if (!loaded) for (auto& p : programs) {
      if (p.users) continue;
      memcpy(p.code, instructions, length * 2);
      p.program = {p.code, static_cast<uint8_t>(length), static_cast<int8_t>(c[0]),
                   static_cast<uint8_t>(c[1]), static_cast<uint8_t>(c[2])};
      if (!pio_can_add_program(pio, &p.program)) break;
      p.offset = pio_add_program(pio, &p.program);
      if (p.offset < 0) break;
      p.pio = pio; loaded = &p; break;
    }
    if (!loaded) pio_sm_unclaim(pio, sm);
  }
  if (!loaded) {
    for (int p = 0; p < static_cast<int>(NUM_BANK0_GPIOS); p++) if (reserved & (uint64_t(1) << p)) gpio_pool_put(p);
    FAIL(ALREADY_IN_USE);
  }
  loaded->users++;
  auto sc = pio_get_default_sm_config();
  sm_config_set_wrap(&sc, loaded->offset + c[3], loaded->offset + c[4]);
  sm_config_set_clkdiv_int_frac8(&sc, divider >> 8, divider & 255);
  if (c[8]) { sm_config_set_in_pin_base(&sc, c[23]); sm_config_set_in_pin_count(&sc, c[8]); }
  if (c[9]) sm_config_set_out_pins(&sc, c[24], c[9]);
  if (c[10]) sm_config_set_set_pins(&sc, c[25], c[10]);
  if (c[5]) { sm_config_set_sideset(&sc, c[5] + c[6], c[6], c[7]); sm_config_set_sideset_pin_base(&sc, c[26]); }
  if (c[27] >= 0) sm_config_set_jmp_pin(&sc, c[27]);
  sm_config_set_in_shift(&sc, c[11], c[13], c[15]);
  sm_config_set_out_shift(&sc, c[12], c[14], c[16]);
  sm_config_set_fifo_join(&sc, static_cast<pio_fifo_join>(c[17]));
  sm_config_set_mov_status(&sc, static_cast<pio_mov_status_type>(c[19]), c[20]);
  auto resource = _new PioResource(group, loaded, sm, sc, pins, outputs, highs, c[21], c[34]);
  if (!resource) {
    pio_sm_unclaim(loaded->pio, sm);
    if (--loaded->users == 0) pio_remove_program(loaded->pio, &loaded->program, loaded->offset);
    for (int p = 0; p < static_cast<int>(NUM_BANK0_GPIOS); p++) if (reserved & (uint64_t(1) << p)) gpio_pool_put(p);
    FAIL(MALLOC_FAILED);
  }
  __atomic_fetch_or(&irq_claims[pio_get_index(loaded->pio)], c[34], __ATOMIC_ACQ_REL);
  for (int pin = 0; pin < static_cast<int>(NUM_BANK0_GPIOS); pin++) if (pins & (uint64_t(1) << pin)) {
    gpio_init(pin);
    gpio_disable_pulls(pin);
  }
  resource->reset();
  for (int pin = 0; pin < static_cast<int>(NUM_BANK0_GPIOS); pin++) if (pins & (uint64_t(1) << pin)) pio_gpio_init(loaded->pio, pin);
  // Registration takes the same event mutex, so release before registering.
  { Unlocker unlocker(locker); group->register_resource(resource); }
  proxy->set_external_address(resource);
  return proxy;
}
PRIMITIVE(close) {
  ARGS(PioResource, resource);
  resource->resource_group()->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(control) {
  ARGS(PioResource, resource, int, operation);
  if (operation < 0 || operation > 2) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  if (operation == 2) {
    if (resource->transfers_[0].data || resource->transfers_[1].data) FAIL(INVALID_STATE);
    resource->reset();
    resource->set_state(0);
  } else pio_sm_set_enabled(resource->pio(), resource->sm_, operation == 1);
  return process->null_object();
}
PRIMITIVE(frequency) {
  ARGS(PioResource, resource);
  uint32_t div = resource->config_.clkdiv;
  double divisor = ((div >> 16) ? (div >> 16) : 65536) + ((div >> 8) & 255) / 256.0;
  return Primitive::allocate_double(clock_get_hz(clk_sys) / divisor, process);
}
PRIMITIVE(submit) {
  ARGS(PioResource, resource, int, direction, Object, bytes, int, size, bool, copy);
  if (direction < 0 || direction > 1 || size <= 0 || size % 4 || size > 16 * 1024 * 1024) FAIL(INVALID_ARGUMENT);
  Blob blob;
  bool supplied = bytes != process->null_object();
  if (supplied && (!bytes->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS) || blob.length() != size)) FAIL(INVALID_ARGUMENT);
  if (!supplied && direction == 0) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  auto& t = resource->transfers_[direction];
  if (t.data) FAIL(ALREADY_IN_USE);
  uint32_t join = resource->config_.shiftctrl & (PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS | PIO_SM0_SHIFTCTRL_FJOIN_TX_BITS |
      PIO_SM0_SHIFTCTRL_FJOIN_RX_GET_BITS | PIO_SM0_SHIFTCTRL_FJOIN_RX_PUT_BITS);
  if ((direction == 0 && (join & PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS)) ||
      (direction == 1 && join && !(join & PIO_SM0_SHIFTCTRL_FJOIN_RX_BITS))) FAIL(INVALID_STATE);
  int channel = dma_claim_unused_channel(false);
  if (channel < 0) FAIL(ALREADY_IN_USE);
  uintptr_t address = supplied ? reinterpret_cast<uintptr_t>(blob.address()) : 0;
  bool dma_sram = address >= SRAM_BASE && address <= SRAM_END &&
      static_cast<uintptr_t>(size) <= SRAM_END - address;
  bool consume = dma_sram && !copy && supplied && is_byte_array(bytes) && ByteArray::cast(bytes)->has_external_address() &&
      ByteArray::cast(bytes)->external_tag() == RawByteTag &&
      !(reinterpret_cast<uintptr_t>(blob.address()) & 3);
  uint8_t* data = consume ? const_cast<uint8_t*>(blob.address()) : static_cast<uint8_t*>(malloc(size));
  if (!data) { dma_channel_unclaim(channel); FAIL(MALLOC_FAILED); }
  if (consume) {
    ByteArray::cast(bytes)->neuter(process);
    ByteArray::cast(bytes)->clear_has_active_finalizer();
  }
  if (direction == 1) memset(data, 0, size);
  else if (!consume) memcpy(data, blob.address(), size);
  t.data = data; t.size = size; t.channel = channel; t.receive = direction == 1;
  auto dc = dma_channel_get_default_config(channel);
  channel_config_set_transfer_data_size(&dc, DMA_SIZE_32);
  channel_config_set_read_increment(&dc, direction == 0);
  channel_config_set_write_increment(&dc, direction == 1);
  channel_config_set_dreq(&dc, pio_get_dreq(resource->pio(), resource->sm_, direction == 0));
  volatile void* destination = direction == 0 ? static_cast<volatile void*>(&resource->pio()->txf[resource->sm_]) : data;
  const volatile void* source = direction == 0 ? data : static_cast<const volatile void*>(&resource->pio()->rxf[resource->sm_]);
  dma_channel_configure(channel, &dc, destination, source, size / 4, false);
  resource->set_state(resource->state() & ~(1u << direction));
  __atomic_fetch_or(&dma_channels, 1u << channel, __ATOMIC_ACQ_REL);
  dma_channel_acknowledge_irq0(channel);
  dma_channel_set_irq0_enabled(channel, true);
  dma_start_channel_mask(1u << channel);
  Rp2350EventDispatcher::instance()->wake();
  return process->null_object();
}
PRIMITIVE(status) {
  ARGS(PioResource, resource, int, direction);
  if (direction < 0 || direction > 1) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  auto& t = resource->transfers_[direction];
  if (!t.data) FAIL(INVALID_STATE);
  return Smi::from(t.status);
}
PRIMITIVE(transferred) {
  ARGS(PioResource, resource, int, direction);
  if (direction < 0 || direction > 1) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  auto& t = resource->transfers_[direction];
  if (!t.data) FAIL(INVALID_STATE);
  return Smi::from(t.status ? t.transferred : t.progress());
}
PRIMITIVE(cancel) {
  ARGS(PioResource, resource, int, direction);
  if (direction < 0 || direction > 1) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  resource->transfers_[direction].cancel();
  Rp2350EventDispatcher::instance()->wake();
  return process->null_object();
}
PRIMITIVE(take) {
  ARGS(PioResource, resource, int, direction, Object, destination);
  if (direction < 0 || direction > 1) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  auto& t = resource->transfers_[direction];
  if (!t.data || !t.status) FAIL(INVALID_STATE);
  Object* result;
  if (destination != process->null_object()) {
    MutableBlob blob;
    Error* error = null;
    if (!destination->mutable_byte_content(process, &blob, &error)) return error;
    if (!blob.address()) FAIL(ALLOCATION_FAILED);
    if (blob.length() != t.size) FAIL(INVALID_ARGUMENT);
    memcpy(blob.address(), t.data, t.size);
    result = destination;
  } else {
    result = process->object_heap()->allocate_external_byte_array(t.size, t.data, true, false);
    if (!result) FAIL(ALLOCATION_FAILED);
    t.data = null;
  }
  __atomic_fetch_and(&dma_channels, ~(1u << t.channel), __ATOMIC_ACQ_REL);
  t.release();
  return result;
}
PRIMITIVE(discard) {
  ARGS(PioResource, resource, int, direction);
  if (direction < 0 || direction > 1) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  auto& t = resource->transfers_[direction];
  if (!t.status) FAIL(INVALID_STATE);
  __atomic_fetch_and(&dma_channels, ~(1u << t.channel), __ATOMIC_ACQ_REL);
  t.release();
  return process->null_object();
}
PRIMITIVE(irq_clear) {
  ARGS(PioResource, resource, int, irq);
  if (irq < 0 || irq > 3 || !(resource->irqs_ & (1u << irq))) FAIL(INVALID_ARGUMENT);
  Locker locker(PioEventSource::instance->mutex());
  resource->pio()->irq = 1u << irq;
  resource->set_state(resource->state() & ~(1u << (8 + irq)));
  hw_set_bits(&resource->pio()->inte0, 1u << (8 + irq));
  return process->null_object();
}
}  // namespace toit
#endif
