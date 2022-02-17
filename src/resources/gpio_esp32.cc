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

#include "../event_sources/gpio_esp32.h"
#include "../event_sources/system_esp32.h"

namespace toit {

enum GPIOState {
  GPIO_STATE_DOWN = 1,
  GPIO_STATE_UP = 2,
};

ResourcePool<int, -1> gpio_pins(
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
    10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    21, 22, 23, 25, 26, 27,
    32, 33, 34, 35, 36, 37, 38, 39
);

class GPIOResourceGroup : public ResourceGroup {
 public:
  TAG(GPIOResourceGroup);
  explicit GPIOResourceGroup(Process* process)
      : ResourceGroup(process, GPIOEventSource::instance()) {}

  virtual void on_unregister_resource(Resource* r) {
    gpio_num_t pin = static_cast<gpio_num_t>(static_cast<IntResource*>(r)->id());
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
    if (pin < 34) gpio_set_level(pin, 0);

    gpio_pins.put(pin);
  }

 private:
  virtual uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return state | (data ? GPIO_STATE_UP : GPIO_STATE_DOWN);
  }
};

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
  ARGS(GPIOResourceGroup, resource_group, int, num);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  if (!gpio_pins.take(num)) ALREADY_IN_USE;

  IntResource* resource = resource_group->register_id(num);
  if (!resource) {
    gpio_pins.put(num)
    MALLOC_FAILED;
  }
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(GPIOResourceGroup, resource_group, IntResource, resource);

  int num = resource->id();
  resource_group->unregister_id(num);
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
