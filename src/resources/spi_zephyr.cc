// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_ZEPHYR
#include "../event_sources/zephyr.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../utils.h"
#include "pins_zephyr.h"
#include <atomic>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/pm/device.h>
#include <zephyr/dt-bindings/pinctrl/nrf-pinctrl.h>

#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
#define DECLARE_SPI(node, prop, i) PINCTRL_DT_DEV_CONFIG_DECLARE(DT_PHANDLE_BY_IDX(node, prop, i));
DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, spi_ports, DECLARE_SPI)
namespace toit {
struct SpiController {
  SpiController(const device* d, pinctrl_dev_config* p) : dev(d), config(p) {}
  const device* dev;
  pinctrl_dev_config* config;
  bool claimed = false, broken = false;
  pinctrl_soc_pin_t active[3], sleep[3];
  pinctrl_state states[2];
  int map(int clock, int mosi, int miso) {
    const int pins[] = {clock, mosi, miso};
    const uint32_t functions[] = {NRF_FUN_SPIM_SCK, NRF_FUN_SPIM_MOSI, NRF_FUN_SPIM_MISO};
    for (int i = 0; i < 3; i++) {
      active[i] = (functions[i] << NRF_FUN_POS) |
          (pins[i] < 0 ? NRF_PIN_DISCONNECTED : static_cast<uint32_t>(pins[i]));
      sleep[i] = active[i] | BIT(NRF_LP_POS);
    }
    states[0] = {active, 3, PINCTRL_STATE_DEFAULT};
    states[1] = {sleep, 3, PINCTRL_STATE_SLEEP};
    return pinctrl_update_states(config, states, 2);
  }
};
#define SPI_CONTROLLER(node, prop, i) {DEVICE_DT_GET(DT_PHANDLE_BY_IDX(node, prop, i)), PINCTRL_DT_DEV_CONFIG_GET(DT_PHANDLE_BY_IDX(node, prop, i))},
static SpiController controllers[] = {
  DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, spi_ports, SPI_CONTROLLER)
};
static SpiController* claim_controller() {
  Locker locker(OS::global_mutex());
  for (auto& controller : controllers) {
    if (!controller.claimed && !controller.broken) { controller.claimed = true; return &controller; }
  }
  return null;
}
class SpiDevice;
class SpiResourceGroup : public ResourceGroup {
 public:
  TAG(SpiResourceGroup);
  explicit SpiResourceGroup(Process* process) : ResourceGroup(process, ZephyrEventSource::instance()) {}
  ~SpiResourceGroup() override {
    ASSERT(active_device == null);
    if (powered_) {
      int result = pm_device_action_run(dev(), PM_DEVICE_ACTION_SUSPEND);
      if (result) FATAL("SPI suspend failed: %d", result);
    }
    pins.release();
    if (controller_) {
      Locker locker(OS::global_mutex());
      controller_->claimed = false;
    }
  }
  int open(int mosi, int miso, int clock) {
    int decoded[3], encoded[] = {mosi, miso, clock};
    for (int i = 0; i < 3; i++) {
      int result = pins.add(encoded[i], &decoded[i]);
      if (result) return result;
    }
    mosi_ = decoded[0]; miso_ = decoded[1];
    controller_ = claim_controller();
    if (!controller_) return -EBUSY;
    int result = controller_->map(decoded[2], mosi_, miso_);
    if (result) return result;
    if (!device_is_ready(dev())) {
      result = device_init(dev());
      if (result) { controller_->broken = true; return result; }
    } else {
      result = pm_device_action_run(dev(), PM_DEVICE_ACTION_RESUME);
      if (result) return result;
    }
    powered_ = true;
    return 0;
  }
  const device* dev() const { return controller_->dev; }
  bool has_mosi() const { return mosi_ >= 0; }
  bool has_miso() const { return miso_ >= 0; }
  void forget(SpiDevice* device) {
    if (last_device_ != device) return;
    // Zephyr caches the spi_config address. Invalidate that cache before its
    // owning device is freed, even if an allocator later reuses the address.
    int result = pm_device_action_run(dev(), PM_DEVICE_ACTION_SUSPEND);
    if (result) FATAL("SPI cache invalidation failed: %d", result);
    result = pm_device_action_run(dev(), PM_DEVICE_ACTION_RESUME);
    if (result) FATAL("SPI resume failed: %d", result);
    last_device_ = null;
  }
  void remember(SpiDevice* device) { last_device_ = device; }
  uint32_t on_event(Resource* resource, word data, uint32_t state) override;
  SpiDevice* active_device = null;
  SpiDevice* reserved_device = null;
  ZephyrPins pins;
 private:
  SpiController* controller_ = null;
  SpiDevice* last_device_ = null;
  bool powered_ = false;
  int mosi_ = -1, miso_ = -1;
};

static void append_bits(uint8_t* out, int* offset, uint64 value, int count) {
  for (int bit = count - 1; bit >= 0; bit--) {
    if ((value >> bit) & 1) out[*offset / 8] |= 1 << (7 - (*offset % 8));
    (*offset)++;
  }
}
class SpiDevice : public ZephyrResource {
 public:
  TAG(SpiDevice);
  SpiDevice(SpiResourceGroup* group, int command_bits, int address_bits, int frequency, int mode)
      : ZephyrResource(group), command_bits_(command_bits), address_bits_(address_bits) {
    config_.frequency = frequency;
    config_.operation = SPI_WORD_SET(8) | SPI_LOCK_ON |
        ((mode & 1) ? SPI_MODE_CPHA : 0) | ((mode & 2) ? SPI_MODE_CPOL : 0);
    k_sem_init(&finished_, 0, 1);
  }
  ~SpiDevice() override {
    abort();
    release_bus();
    group()->forget(this);
    if (group()->reserved_device == this) group()->reserved_device = null;
  }
  SpiResourceGroup* group() const { return static_cast<SpiResourceGroup*>(resource_group()); }
  int open(int cs, int dc) {
    int decoded_cs;
    int result = pins.add(cs, &decoded_cs);
    if (result) return result;
    result = pins.add(dc, &dc_);
    if (result) return result;
    if (decoded_cs >= 0) {
      config_.cs.gpio = {zephyr_gpio_port(decoded_cs), static_cast<gpio_pin_t>(decoded_cs % 32), GPIO_ACTIVE_LOW};
      config_.cs.cs_is_gpio = true;
      config_.cs.delay = 1;
      result = gpio_pin_configure_dt(&config_.cs.gpio, GPIO_OUTPUT_INACTIVE);
      if (result) return result;
    }
    if (dc_ >= 0) return gpio_pin_configure(zephyr_gpio_port(dc_), dc_ % 32, GPIO_OUTPUT_LOW);
    return 0;
  }
  int start(const uint8_t* bytes, int length, int command, int64 address, bool read, int dc, bool keep) {
    Locker locker(group()->event_source()->mutex());
    if (group()->active_device) return -EBUSY;
    if (group()->reserved_device && group()->reserved_device != this) return -EPERM;
    if (keep && group()->reserved_device != this) return -EPERM;
    if ((read && !group()->has_miso()) || (!read && !group()->has_mosi())) return -EINVAL;
    int prefix = (command_bits_ + address_bits_) / 8;
    if (length > 65536 - prefix) return -EMSGSIZE;
    int total = prefix + length;
    if (!total) return -EINVAL;
    tx_ = static_cast<uint8_t*>(malloc(total));
    if (!tx_) return -ENOMEM;
    if (read) {
      rx_ = static_cast<uint8_t*>(malloc(total));
      if (!rx_) { free(tx_); tx_ = null; return -ENOMEM; }
    }
    memset(tx_, 0, prefix);
    int offset = 0;
    append_bits(tx_, &offset, static_cast<uint32>(command), command_bits_);
    append_bits(tx_, &offset, static_cast<uint64>(address), address_bits_);
    memcpy(tx_ + prefix, bytes, length);
    tx_buffer_ = {tx_, static_cast<size_t>(total)};
    rx_buffer_ = {rx_, static_cast<size_t>(total)};
    tx_buffers_ = {&tx_buffer_, 1};
    rx_buffers_ = {&rx_buffer_, 1};
    length_ = length;
    keep_ = keep;
    done_.store(false);
    take_pending();
    k_sem_reset(&finished_);
    if (dc_ >= 0) gpio_pin_set(zephyr_gpio_port(dc_), dc_ % 32, dc != 0);
    if (keep) config_.operation |= SPI_HOLD_ON_CS;
    else config_.operation &= ~SPI_HOLD_ON_CS;
    active_ = true;
    group()->active_device = this;
    group()->remember(this);
    native_locked_ = true;
    int result = spi_transceive_cb(group()->dev(), &config_, &tx_buffers_, read ? &rx_buffers_ : null, complete, this);
    if (result) {
      release_bus();
      retire_locked();
    }
    return result;
  }
  bool completed() const { return active_ && done_.load(); }
  int length() const { return length_; }
  int finish(uint8_t* bytes, bool read) {
    Locker locker(group()->event_source()->mutex());
    if (!active_) return -EINVAL;
    if (!done_.load()) return 0;
    int result = result_;
    if (!keep_ || result) {
      int released = release_bus();
      if (released == -EBUSY) return 0;
      if (released && !result) result = released;
    }
    if (!result && read && rx_) memcpy(bytes, rx_ + (command_bits_ + address_bits_) / 8, length_);
    retire_locked();
    return result ? result : 1;
  }
  void abort() {
    if (!active_) return;
    // Zephyr has no public SPIM abort hook. Master clocks bound accepted
    // transfers to at most 65536 bytes / 125 kHz, before buffers can be freed.
    if (!done_.load() && k_sem_take(&finished_, K_SECONDS(5))) FATAL("SPI DMA did not stop");
    Locker locker(group()->event_source()->mutex());
    int result = release_bus();
    if (result) FATAL("SPI release failed: %d", result);
    retire_locked();
  }
  int release_bus() {
    if (native_locked_) {
      int result = spi_release(group()->dev(), &config_);
      if (result == -EBUSY) return result;
      if (result && result != -EALREADY && result != -EINVAL) return result;
      native_locked_ = false;
    }
    if (config_.cs.cs_is_gpio) gpio_pin_set_dt(&config_.cs.gpio, 0);
    return 0;
  }
  ZephyrPins pins;
 private:
  static void complete(const device*, int result, void* context) {
    auto self = static_cast<SpiDevice*>(context);
    self->result_ = result;
    self->done_.store(true);
    self->notify(1);
    k_sem_give(&self->finished_);
  }
  void retire_locked() {
    active_ = false;
    group()->active_device = null;
    take_pending();
    free(tx_); free(rx_);
    tx_ = rx_ = null;
    length_ = 0;
  }
  spi_config config_ = {};
  spi_buf tx_buffer_ = {}, rx_buffer_ = {};
  spi_buf_set tx_buffers_ = {}, rx_buffers_ = {};
  uint8_t* tx_ = null;
  uint8_t* rx_ = null;
  int command_bits_, address_bits_, dc_ = -1, length_ = 0, result_ = 0;
  bool active_ = false, keep_ = false, native_locked_ = false;
  std::atomic<bool> done_{false};
  k_sem finished_;
};
uint32_t SpiResourceGroup::on_event(Resource* resource, word, uint32_t state) {
  return static_cast<SpiDevice*>(resource)->completed() ? state | 1 : state;
}

MODULE_IMPLEMENTATION(spi, MODULE_SPI)
PRIMITIVE(init) {
  ARGS(int, mosi, int, miso, int, clock);
  if (clock == -1 || (mosi == -1 && miso == -1)) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto group = _new SpiResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);
  bool adopted = false;
  Defer cleanup{[&] { if (!adopted) group->tear_down(); }};
  int result = group->open(mosi, miso, clock);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result == -EPERM) FAIL(PERMISSION_DENIED);
  if (result == -EINVAL) FAIL(INVALID_ARGUMENT);
  if (result) return Primitive::os_error(-result, process);
  proxy->set_external_address(group);
  adopted = true;
  return proxy;
}
PRIMITIVE(close) {
  ARGS(SpiResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(device) {
  ARGS(SpiResourceGroup, group, int, cs, int, dc, int, command_bits, int, address_bits,
       int, frequency, int, mode, int, cs_setup_cycles, int, cs_hold_cycles);
  if (cs_setup_cycles || cs_hold_cycles) FAIL(UNIMPLEMENTED);
  if (command_bits < 0 || command_bits > 16 || address_bits < 0 || address_bits > 64 ||
      (command_bits + address_bits) % 8 || mode < 0 || mode > 3 || frequency < 125000) FAIL(INVALID_ARGUMENT);
  if ((command_bits || address_bits) && !group->has_mosi()) FAIL(INVALID_ARGUMENT);
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (!proxy) FAIL(ALLOCATION_FAILED);
  auto device = _new SpiDevice(group, command_bits, address_bits, frequency, mode);
  if (!device) FAIL(MALLOC_FAILED);
  group->register_resource(device);
  AutoUnregisteringResource<SpiDevice> cleanup(group, device);
  int result = device->open(cs, dc);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result == -EPERM) FAIL(PERMISSION_DENIED);
  if (result == -EINVAL) FAIL(INVALID_ARGUMENT);
  if (result) return Primitive::os_error(-result, process);
  cleanup.set_external_address(proxy);
  return proxy;
}
PRIMITIVE(device_close) {
  ARGS(SpiResourceGroup, group, SpiDevice, device);
  group->unregister_resource(device);
  device_proxy->clear_external_address();
  return process->null_object();
}
PRIMITIVE(transfer_start) {
  ARGS(SpiDevice, device, Blob, bytes, int, command, int64, address, int, from, int, to, bool, read, int, dc, bool, keep);
  if (from < 0 || from > to || to > bytes.length()) FAIL(OUT_OF_BOUNDS);
  int result = device->start(bytes.address() + from, to - from, command, address, read, dc, keep);
  if (result == -EBUSY) FAIL(ALREADY_IN_USE);
  if (result == -EPERM) FAIL(INVALID_STATE);
  if (result == -EINVAL) FAIL(INVALID_ARGUMENT);
  if (result == -EMSGSIZE) FAIL(OUT_OF_RANGE);
  if (result == -ENOMEM) FAIL(MALLOC_FAILED);
  if (result) return Primitive::os_error(-result, process);
  return process->null_object();
}
PRIMITIVE(transfer_finish) {
  ARGS(SpiDevice, device, MutableBlob, output, int, from, bool, read);
  if (from < 0 || from > output.length() || device->length() > output.length() - from) FAIL(OUT_OF_BOUNDS);
  int result = device->finish(output.address() + from, read);
  if (result < 0) return Primitive::os_error(-result, process);
  return BOOL(result != 0);
}
PRIMITIVE(transfer_abort) { ARGS(SpiDevice, device); device->abort(); return process->true_object(); }
PRIMITIVE(acquire_bus) {
  ARGS(SpiDevice, device);
  if (device->group()->active_device || device->group()->reserved_device) return process->false_object();
  device->group()->reserved_device = device;
  return process->true_object();
}
PRIMITIVE(release_bus) {
  ARGS(SpiDevice, device);
  if (device->group()->reserved_device != device) FAIL(INVALID_STATE);
  int result = device->release_bus();
  if (result) return Primitive::os_error(-result, process);
  device->group()->reserved_device = null;
  return process->null_object();
}
PRIMITIVE(target_init) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_create) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_close) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_transfer_start) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(target_transfer_finish) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_create) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_arm) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_close) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_get) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_set) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_read) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_write) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_receive) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(buffer_target_dropped_receive_count) { FAIL(UNIMPLEMENTED); }
}  // namespace toit
#endif
