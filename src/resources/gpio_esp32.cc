// Copyright (C) 2018 Toitware ApS.
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

#include <driver/gpio.h>
#include <hal/gpio_hal.h>

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "../entropy_mixer.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

#include "../event_sources/ev_queue_esp32.h"
#include "../event_sources/system_esp32.h"

namespace toit {

enum GpioState {
  GPIO_STATE_EDGE_TRIGGERED = 1,
};
/*
GPIO summary:
- Esp32: https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/gpio.html
- Esp32c3: https://docs.espressif.com/projects/esp-idf/en/stable/esp32c3/api-reference/peripherals/gpio.html
- Esp32c6: https://docs.espressif.com/projects/esp-idf/en/stable/esp32c6/api-reference/peripherals/gpio.html
- Esp32s2: https://docs.espressif.com/projects/esp-idf/en/stable/esp32s2/api-reference/peripherals/gpio.html
- Esp32s3: https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/peripherals/gpio.html
*/

static ResourcePool<int, -1> gpio_pins(
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
#ifdef CONFIG_IDF_TARGET_ESP32
    21, 22, 23, 25, 26, 27,
    32, 33, 34, 35, 36, 37, 38, 39
#elif CONFIG_IDF_TARGET_ESP32C3
    20, 21
#elif CONFIG_IDF_TARGET_ESP32C6
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30
#elif CONFIG_IDF_TARGET_ESP32S3
    20, 21, 26, 27, 28, 29,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47, 48
#elif CONFIG_IDF_TARGET_ESP32S2
    20, 21, 26, 27, 28, 29,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46
#else
#error Unknown ESP32 target architecture
#endif
);

#ifdef CONFIG_IDF_TARGET_ESP32
static bool is_restricted_pin(int num) {
  // The flash pins should generally not be used.
  return 6 <= num && num <= 11;
}
#elif CONFIG_IDF_TARGET_ESP32C3
static bool is_restricted_pin(int num) {
  // The flash pins should generally not be used.
  return 12 <= num && num <= 17;
}
#elif CONFIG_IDF_TARGET_ESP32C6
static bool is_restricted_pin(int num) {
  // Pins 24-30 are used for flash and PSRAM.
  return 24 <= num && num <= 30;
}
#elif CONFIG_IDF_TARGET_ESP32S3
static bool is_restricted_pin(int num) {
  // Pins 26-32 are used for flash, and pins 33-37 are used for
  // octal flash or octal PSRAM.
  return 26 <= num && num <= 37;
}
#elif CONFIG_IDF_TARGET_ESP32S2
static bool is_restricted_pin(int num) {
  // Pins 26-32 are used for flash and PSRAM.
  return 26 <= num && num <= 32;
}
#else
#error Unknown ESP32 target architecture

static bool is_restricted_pin(int num) {
  return false;
}

#endif

class GpioResource : public EventQueueResource {
 public:
  TAG(GpioResource);

  GpioResource(ResourceGroup* group, int pin)
      // GPIO resources share a queue, which is always on the event source, so pass null.
      : EventQueueResource(group, null)
      , pin_(pin)
      , interrupt_listeners_count_(0)
      , last_edge_detection_(-1)
      {}

  int pin() const { return pin_; }

  bool check_gpio(word pin) override;

  /// Increments the number of interrupt listeners.
  /// Returns true if this is the first interrupt listener.
  bool increment_interrupt_listeners_count() {
    interrupt_listeners_count_++;
    return interrupt_listeners_count_ == 1;
  }

  /// Decrements the number of interrupt listeners.
  /// Returns true if this was the last interrupt listener.
  bool decrement_interrupt_listeners_count() {
    interrupt_listeners_count_--;
    return interrupt_listeners_count_ == 0;
  }

  void set_last_edge_detection_timestamp(word timestamp) {
    last_edge_detection_ = timestamp;
  }

  word last_edge_detection() const { return last_edge_detection_; }

 private:
  int pin_;
  // The number of users that have enabled interrupts.
  int interrupt_listeners_count_;
  // The timestamp for which an edge transition was detected.
  // Any user that started listening after this value should ignore the transition.
  word last_edge_detection_;
};

class GpioResourceGroup : public ResourceGroup {
 public:
  TAG(GpioResourceGroup);
  explicit GpioResourceGroup(Process* process)
      : ResourceGroup(process, EventQueueEventSource::instance()) {
    queue = EventQueueEventSource::instance()->gpio_queue();
  }

  virtual void on_register_resource(Resource* r);
  virtual void on_unregister_resource(Resource* r);

 private:
  virtual uint32_t on_event(Resource* resource, word data, uint32_t state) {
    static_cast<GpioResource*>(resource)->set_last_edge_detection_timestamp(static_cast<int>(data));
    return state | GPIO_STATE_EDGE_TRIGGERED;
  }

  static QueueHandle_t queue;

  static void IRAM_ATTR isr_handler(void* arg);
};

void GpioResourceGroup::on_register_resource(Resource* r) {
  gpio_num_t pin = static_cast<gpio_num_t>(static_cast<GpioResource*>(r)->pin());
  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(gpio_isr_handler_add(pin, isr_handler, reinterpret_cast<void*>(pin)));
    // The gpio_isr_handler_add also enables interrupts on the pin. This is undesirable as all changes to the
    // pin will then call the ISR. In Toit, we pass the Pin object around to other peripherals, and therefore we
    // do not really want an interrupt to fire on a pin unless it is specifically being used as an input pin.
    FATAL_IF_NOT_ESP_OK(gpio_intr_disable(pin));
  });
}

void GpioResourceGroup::on_unregister_resource(Resource* r) {
  gpio_num_t pin = static_cast<gpio_num_t>(static_cast<GpioResource*>(r)->pin());

  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(gpio_isr_handler_remove(gpio_num_t(pin)));
  });

  // Clear all state associated with the GPIO pin.
  // NOTE: Don't use gpio_reset_pin - it will put on an internal pull-up that's
  // kept during deep sleep.

  gpio_config_t cfg = {
    .pin_bit_mask = 1ULL << pin,
    .mode = GPIO_MODE_DISABLE,
    .pull_up_en = GPIO_PULLUP_DISABLE,
    .pull_down_en = GPIO_PULLDOWN_DISABLE,
    .intr_type = GPIO_INTR_DISABLE,
  };
  gpio_config(&cfg);
  if (GPIO_IS_VALID_OUTPUT_GPIO(pin)) gpio_set_level(pin, 0);

  gpio_pins.put(pin);
}

QueueHandle_t GpioResourceGroup::queue;

// A counter for interrupt-enabling requests.
// We use this counter instead of a timestamp which is hard to get inside an interrupt
// handler.
// When a user requests to be informed about interrupts, we increment the counter.
// When an interrupt triggers, it records the current counter, and pushes the event
// into a queue. (Sligthly) later the event is taken out of the queue and used to
// notify all users that are listening at that moment. Due to race conditions, there
// might be users now that weren't subscribed when the event actually happened.
// We pass the counter so that they can determine whether the event is actually
// relevant to them.
static word isr_counter = 0;

void IRAM_ATTR GpioResourceGroup::isr_handler(void* arg) {
  GpioEvent event {
    .pin = unvoid_cast<word>(arg),
    // Since real timestamps are hard to get inside an interrupt handler, we use
    // the isr_counter instead. It is monotonically increasing and grows exactly when
    // we need the values to change.
    .timestamp = isr_counter,
  };
  xQueueSendToBackFromISR(queue, &event, null);
  return;
}

bool GpioResource::check_gpio(word pin) {
  return pin == pin_;
}

MODULE_IMPLEMENTATION(gpio, MODULE_GPIO)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  GpioResourceGroup* gpio = _new GpioResourceGroup(process);
  if (!gpio) FAIL(MALLOC_FAILED);

  proxy->set_external_address(gpio);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(GpioResourceGroup, resource_group, int, num, bool, allow_restricted);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  if (!allow_restricted && is_restricted_pin(num)) {
    FAIL(PERMISSION_DENIED);
  }

  if (!gpio_pins.take(num)) FAIL(ALREADY_IN_USE);

  GpioResource* resource = _new GpioResource(resource_group, num);
  if (!resource) {
    gpio_pins.put(num);
    FAIL(MALLOC_FAILED);
  }
  resource_group->register_resource(resource);

  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(GpioResourceGroup, resource_group, GpioResource, resource);

  resource_group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(config) {
  ARGS(int, num, bool, pull_up, bool, pull_down, bool, input, bool, output, bool, open_drain, int, value);

  gpio_config_t cfg = {
    .pin_bit_mask = 1ULL << num,
    .mode = GPIO_MODE_OUTPUT_OD,
    .pull_up_en = static_cast<gpio_pullup_t>(pull_up),
    .pull_down_en = static_cast<gpio_pulldown_t>(pull_down),
    .intr_type = GPIO_INTR_DISABLE,
  };

  if (output) {
    // Set the value before switching the mode.
    // This may be harmful if the pin switches from push-pull to open-drain.
    // Specifically, if the pin is push-pull and set to GND, then switching to
    // open-drain with 1 could cause a short-circuit (if another device is
    // currently driving the line to low).
    // We don't have an easy way to know in which state the pin currently is, so
    // we just require users to pay attention to this.
    if (value != -1) {
      esp_err_t err = gpio_set_level((gpio_num_t)num, value);
      if (err != ESP_OK) return Primitive::os_error(err, process);
    }
  }

  if (input) {
    cfg.intr_type = GPIO_INTR_ANYEDGE;
  }

  if (input && output && open_drain) cfg.mode = GPIO_MODE_INPUT_OUTPUT_OD;
  else if (input && output) cfg.mode = GPIO_MODE_INPUT_OUTPUT;
  else if (input) cfg.mode = GPIO_MODE_INPUT;
  else if (output && open_drain) cfg.mode = GPIO_MODE_OUTPUT_OD;
  else if (output) cfg.mode = GPIO_MODE_OUTPUT;
  else cfg.mode = GPIO_MODE_DISABLE;

  esp_err_t err = gpio_config(&cfg);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  if (input) {
    // The gpio driver enables interrupts automatically for input pins. Since this is handled more fine-grained
    // in config_interrupt we disable the interrupt.
    err = gpio_intr_disable(static_cast<gpio_num_t>(num));
    if (err != ESP_OK) return Primitive::os_error(err, process);
  }

  return process->null_object();
}

PRIMITIVE(config_interrupt) {
  ARGS(GpioResource, resource, bool, enable);
  esp_err_t err = ESP_OK;
  gpio_num_t num = static_cast<gpio_num_t>(resource->pin());
  if (enable) {
    if (resource->increment_interrupt_listeners_count()) {
      SystemEventSource::instance()->run([&]() -> void {
        err = gpio_intr_enable(num);
      });
    }
  } else {
    if (resource->decrement_interrupt_listeners_count()) {
      SystemEventSource::instance()->run([&]() -> void {
        err = gpio_intr_disable(num);
      });
    }
  }
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Smi::from((isr_counter++) & 0x3FFFFFFF);
}

// A very low-level change of open-drain.
// If the pin is used in some peripheral, a call to this primitive doesn't
// affect that configuration.
PRIMITIVE(set_open_drain) {
  ARGS(int, num, bool, enable);
  if (num < 0 || num >= GPIO_NUM_MAX) FAIL(INVALID_ARGUMENT);

  // Change the open-drain bit.
  // Directly writes to the memory-mapped register.
  GPIO.pin[num].pad_driver = enable ? 1 : 0;

  return process->null_object();
}

// A very low-level change of pull-up/down.
// If the pin is used in some peripheral, a call to this primitive doesn't
// affect that configuration.
PRIMITIVE(set_pull) {
  ARGS(int, num, int, direction);
  if (num < 0 || num >= GPIO_NUM_MAX) FAIL(INVALID_ARGUMENT);

  gpio_pull_mode_t mode;
  if (direction == 0) {
    mode = GPIO_FLOATING;
  } else if (direction < 0) {
    mode = GPIO_PULLDOWN_ONLY;
  } else {
    mode = GPIO_PULLUP_ONLY;
  }
  esp_err_t err = gpio_set_pull_mode(static_cast<gpio_num_t>(num), mode);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
}

PRIMITIVE(last_edge_trigger_timestamp) {
  ARGS(GpioResource, resource);
  return Smi::from(resource->last_edge_detection() & 0x3FFFFFFF);
}

PRIMITIVE(get) {
  ARGS(int, num);

  return Smi::from(gpio_get_level((gpio_num_t)num));
}

PRIMITIVE(set) {
  ARGS(int, num, int, value);

  esp_err_t err = gpio_set_level((gpio_num_t)num, value);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->null_object();
}

} // namespace toit

#endif // TOIT_ESP32
