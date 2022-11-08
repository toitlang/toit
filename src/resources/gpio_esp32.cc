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

#ifdef TOIT_FREERTOS

#include <driver/gpio.h>
#include <driver/adc.h>
#include <esp_adc_cal.h>

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

enum GPIOState {
  GPIO_STATE_DOWN = 1,
  GPIO_STATE_UP = 2,
};

ResourcePool<int, -1> gpio_pins(
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
#ifdef CONFIG_IDF_TARGET_ESP32S3
    20, 21, 26, 27, 28, 29,
    30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47, 48, 49
#else
    21, 22, 23, 25, 26, 27,
    32, 33, 34, 35, 36, 37, 38, 39
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

class GPIOResource : public EventQueueResource {
 public:
  TAG(GPIOResource);

  GPIOResource(ResourceGroup* group, int pin)
      // GPIO resources share a queue, which is always on the event source, so pass null.
      : EventQueueResource(group, null)
      , pin_(pin) {}

  int pin() const { return pin_; }

  bool check_gpio(word pin) override;

 private:
  int pin_;
};

class GPIOResourceGroup : public ResourceGroup {
 public:
  TAG(GPIOResourceGroup);
  explicit GPIOResourceGroup(Process* process)
      : ResourceGroup(process, EventQueueEventSource::instance()) {
    queue = EventQueueEventSource::instance()->gpio_queue();
  }

  virtual void on_register_resource(Resource* r);
  virtual void on_unregister_resource(Resource* r);

 private:
  virtual uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return state | (data ? GPIO_STATE_UP : GPIO_STATE_DOWN);
  }

  static QueueHandle_t IRAM_ATTR queue;

  static void IRAM_ATTR isr_handler(void* arg);
};

void GPIOResourceGroup::on_register_resource(Resource* r) {
  gpio_num_t pin = static_cast<gpio_num_t>(static_cast<GPIOResource*>(r)->pin());
  SystemEventSource::instance()->run([&]() -> void {
    FATAL_IF_NOT_ESP_OK(gpio_isr_handler_add(pin, isr_handler, reinterpret_cast<void*>(pin)));
  });
}

void GPIOResourceGroup::on_unregister_resource(Resource* r) {
  gpio_num_t pin = static_cast<gpio_num_t>(static_cast<GPIOResource*>(r)->pin());

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

QueueHandle_t IRAM_ATTR GPIOResourceGroup::queue;

void IRAM_ATTR GPIOResourceGroup::isr_handler(void* arg) {
  word id = unvoid_cast<word>(arg);
  xQueueSendToBackFromISR(queue, &id, null);
  return;
}

bool GPIOResource::check_gpio(word pin) {
  if (pin != pin_) return false;
  return true;
}

MODULE_IMPLEMENTATION(gpio, MODULE_GPIO)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  GPIOResourceGroup* gpio = _new GPIOResourceGroup(process);
  if (!gpio) MALLOC_FAILED;

  proxy->set_external_address(gpio);
  return proxy;
}

PRIMITIVE(use) {
  ARGS(GPIOResourceGroup, resource_group, int, num, bool, allow_restricted);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (!allow_restricted && is_restricted_pin(num)) INVALID_ARGUMENT;

  if (!gpio_pins.take(num)) ALREADY_IN_USE;

  GPIOResource* resource = _new GPIOResource(resource_group, num);
  if (!resource) {
    gpio_pins.put(num);
    MALLOC_FAILED;
  }
  resource_group->register_resource(resource);

  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(GPIOResourceGroup, resource_group, GPIOResource, resource);

  resource_group->unregister_resource(resource);
  resource_proxy->clear_external_address();
  return process->program()->null_object();
}

PRIMITIVE(config) {
  ARGS(int, num, bool, pull_up, bool, pull_down, bool, input, bool, output, bool, open_drain);

  gpio_config_t cfg = {
    .pin_bit_mask = 1ULL << num,
    .mode = GPIO_MODE_OUTPUT_OD,
    .pull_up_en = static_cast<gpio_pullup_t>(pull_up),
    .pull_down_en = static_cast<gpio_pulldown_t>(pull_down),
    .intr_type = GPIO_INTR_DISABLE,
  };

  if (input) {
    cfg.intr_type = GPIO_INTR_ANYEDGE;
    if (output) {
      cfg.mode = open_drain ? GPIO_MODE_INPUT_OUTPUT_OD : GPIO_MODE_INPUT_OUTPUT;
    } else {
      cfg.mode = GPIO_MODE_INPUT;
    }
  } else if (output) {
    cfg.mode = open_drain ? GPIO_MODE_OUTPUT_OD : GPIO_MODE_OUTPUT;
  }

  esp_err_t err = gpio_config(&cfg);;
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(config_interrupt) {
  ARGS(int, num, bool, enable);
  esp_err_t err = ESP_OK;
  CAPTURE3(int, num, bool, enable, esp_err_t&, err);
  SystemEventSource::instance()->run([&]() -> void {
    if (capture.enable) {
      capture.err = gpio_intr_enable((gpio_num_t)capture.num);
    } else {
      capture.err = gpio_intr_disable((gpio_num_t)capture.num);
    }
  });
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

PRIMITIVE(get) {
  ARGS(int, num);

  return Smi::from(gpio_get_level((gpio_num_t)num));
}

PRIMITIVE(set) {
  ARGS(int, num, int, value);

  esp_err_t err = gpio_set_level((gpio_num_t)num, value);
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

} // namespace toit

#endif // TOIT_FREERTOS
