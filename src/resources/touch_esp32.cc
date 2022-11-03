// Copyright (C) 2021 Toitware ApS.
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

#if defined(CONFIG_IDF_TARGET_ESP32) || defined(CONFIG_IDF_TARGET_ESP32S2) || defined(CONFIG_IDF_TARGET_ESP32S3)

#include <driver/gpio.h>
#include <driver/touch_sensor.h>

#include "touch_esp32.h"

#include "../entropy_mixer.h"
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../vm.h"

namespace toit {

static constexpr touch_pad_t kInvalidTouchPad = static_cast<touch_pad_t>(-1);

#ifdef CONFIG_IDF_TARGET_ESP32

static touch_pad_t get_touch_pad(int pin) {
  switch (pin) {
    case 0:  return TOUCH_PAD_NUM1;
    case 2:  return TOUCH_PAD_NUM2;
    case 4:  return TOUCH_PAD_NUM0;
    case 12: return TOUCH_PAD_NUM5;
    case 13: return TOUCH_PAD_NUM4;
    case 14: return TOUCH_PAD_NUM6;
    case 15: return TOUCH_PAD_NUM3;
    case 27: return TOUCH_PAD_NUM7;
    case 32: return TOUCH_PAD_NUM9;
    case 33: return TOUCH_PAD_NUM8;
    default: return kInvalidTouchPad;
  }
}

int touch_pad_to_pin_num(touch_pad_t pad) {
  switch (pad) {
    case TOUCH_PAD_NUM1: return 0;
    case TOUCH_PAD_NUM2: return 2;
    case TOUCH_PAD_NUM0: return 4;
    case TOUCH_PAD_NUM5: return 12;
    case TOUCH_PAD_NUM4: return 13;
    case TOUCH_PAD_NUM6: return 14;
    case TOUCH_PAD_NUM3: return 15;
    case TOUCH_PAD_NUM7: return 27;
    case TOUCH_PAD_NUM9: return 32;
    case TOUCH_PAD_NUM8: return 33;
    default: return -1;
  }
}

#elif CONFIG_IDF_TARGET_ESP32S2 || CONFIG_IDF_TARGET_ESP32S3

static touch_pad_t get_touch_pad(int pin) {
  switch (pin) {
    case 1:  return TOUCH_PAD_NUM1;
    case 2:  return TOUCH_PAD_NUM2;
    case 3:  return TOUCH_PAD_NUM3;
    case 4:  return TOUCH_PAD_NUM4;
    case 5:  return TOUCH_PAD_NUM5;
    case 6:  return TOUCH_PAD_NUM6;
    case 7:  return TOUCH_PAD_NUM7;
    case 8:  return TOUCH_PAD_NUM8;
    case 9:  return TOUCH_PAD_NUM9;
    case 10: return TOUCH_PAD_NUM10;
    case 11: return TOUCH_PAD_NUM11;
    case 12: return TOUCH_PAD_NUM12;
    case 13: return TOUCH_PAD_NUM13;
    case 14: return TOUCH_PAD_NUM14;
    default: return kInvalidTouchPad;
  }
}

int touch_pad_to_pin_num(touch_pad_t pad) {
  switch (pad) {
    case TOUCH_PAD_NUM1:  return 1;
    case TOUCH_PAD_NUM2:  return 2;
    case TOUCH_PAD_NUM3:  return 3;
    case TOUCH_PAD_NUM4:  return 4;
    case TOUCH_PAD_NUM5:  return 5;
    case TOUCH_PAD_NUM6:  return 6;
    case TOUCH_PAD_NUM7:  return 7;
    case TOUCH_PAD_NUM8:  return 8;
    case TOUCH_PAD_NUM9:  return 9;
    case TOUCH_PAD_NUM10: return 10;
    case TOUCH_PAD_NUM11: return 11;
    case TOUCH_PAD_NUM12: return 12;
    case TOUCH_PAD_NUM13: return 13;
    case TOUCH_PAD_NUM14: return 14;
    default: return -1;
  }
}

#elif CONFIG_IDF_TARGET_ESP32C3

static touch_pad_t get_touch_pad(int pin) {
  // ESP32C3 does not have touch support.
  return kInvalidTouchPad;
}

int touch_pad_to_pin_num(touch_pad_t pad) {
  // ESP32C3 does not have touch support.
  return -1;
}

#elif CONFIG_IDF_TARGET_ESP32

#error "Unsupported ESP32 target"

#else

static touch_pad_t get_touch_pad(int pin) {
  return kInvalidTouchPad;
}

int touch_pad_to_pin_num(touch_pad_t pad) {
  return -1;
}

#endif

// When using touch pads for deep sleep wakeup we must not deinit the touch
// pad when the resource-group is torn down.
static bool should_keep_touch_active = false;
static bool touch_is_initialized = false;
static int touch_user_count = 0;

void keep_touch_active() {
  should_keep_touch_active = true;
}

class TouchResourceGroup : public ResourceGroup {
 public:
  TAG(TouchResourceGroup);
  explicit TouchResourceGroup(Process* process)
      : ResourceGroup(process) {}

  // Make the delete public.
  // Avoid using this constructor except when initializing the group, but needing
  // to bail out.
  void operator delete(void* ptr) {
    ResourceGroup::operator delete(ptr);
  }


  void tear_down() override {
    {
      Locker locker(OS::resource_mutex());
      touch_user_count--;
      if (touch_user_count == 0 && !should_keep_touch_active) {
        touch_pad_deinit();
        touch_is_initialized = false;
      }
    }
    // Clear the status field which would be used to determine
    // which pin woke the ESP32 from deep-sleep.
    touch_pad_clear_status();
    ResourceGroup::tear_down();
  }

  virtual void on_unregister_resource(Resource* resource) override {
    touch_pad_t pad = static_cast<touch_pad_t>(static_cast<IntResource*>(resource)->id());

    // Reset the threshold so it's not use for deep-sleep wake-ups.
    if (!should_keep_touch_active) {
      touch_pad_set_thresh(pad, 0);
    }

    // Apparently there is nothing else to do to free touch pins.
    // Asked on the forum: https://www.esp32.com/viewtopic.php?f=13&t=28973
  }

};

MODULE_IMPLEMENTATION(touch, MODULE_TOUCH)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  TouchResourceGroup* touch = _new TouchResourceGroup(process);
  if (!touch) MALLOC_FAILED;

  Locker locker(OS::resource_mutex());

  if (touch_user_count == 0 && !touch_is_initialized) {
    esp_err_t err = touch_pad_init();
    if (err != ESP_OK) {
      process->remove_resource_group(touch);
      delete touch;
      return Primitive::os_error(err, process);
    }

    ESP_ERROR_CHECK(touch_pad_set_voltage(TOUCH_HVOLT_2V7, TOUCH_LVOLT_0V5, TOUCH_HVOLT_ATTEN_1V));
    // Start the hard-ware FSM, so that `touch_pad_get_status` is up to date.
    // The hardware FSM is also necessary for waking up from deep-sleep.
    ESP_ERROR_CHECK(touch_pad_set_fsm_mode(TOUCH_FSM_MODE_TIMER));

    touch_is_initialized = true;
    touch_user_count++;
  }

  proxy->set_external_address(touch);
  return proxy;
}


PRIMITIVE(use) {
  ARGS(TouchResourceGroup, resource_group, int, num, uint16, threshold);
  // We assume that the process already owns the pin.
  // This obviously fails, if someone calls the primitive directly without acquiring the pin first.

  touch_pad_t pad = get_touch_pad(num);
  if (pad == kInvalidTouchPad) OUT_OF_RANGE;

  auto resource = _new IntResource(resource_group, pad);
  if (!resource) MALLOC_FAILED;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

#if CONFIG_IDF_TARGET_ESP32S3 || CONFIG_IDF_TARGET_ESP32S2
  esp_err_t err = touch_pad_config(pad);
  if (err == ESP_OK) {
    err = touch_pad_set_thresh(pad, threshold);
  }
#else
  esp_err_t err = touch_pad_config(pad, threshold);
#endif
  if (err != ESP_OK) return Primitive::os_error(err, process);

  resource_group->register_resource(resource);
  proxy->set_external_address(resource);

  return proxy;
}

PRIMITIVE(unuse) {
  ARGS(TouchResourceGroup, resource_group, IntResource, resource);
  touch_pad_t pad = static_cast<touch_pad_t>(static_cast<IntResource*>(resource)->id());

  // This call is an explicit 'close' call, so make sure the touch pad is deactived.
  // Unregistering the resource won't do that if we have to keep the touch pad alive for
  // deep sleep.
  touch_pad_set_thresh(pad, 0);
  resource_group->unregister_resource(resource);
  resource_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(read) {
  ARGS(IntResource, resource);
  touch_pad_t pad = static_cast<touch_pad_t>(resource->id());

#ifdef CONFIG_IDF_TARGET_ESP32
  uint16_t val;
#else
  uint32_t val;
#endif
  esp_err_t err = touch_pad_read_raw_data(pad, &val);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Smi::from(static_cast<int>(val));
}

PRIMITIVE(get_threshold) {
  ARGS(IntResource, resource);
  touch_pad_t pad = static_cast<touch_pad_t>(resource->id());

#if CONFIG_IDF_TARGET_ESP32S3 || CONFIG_IDF_TARGET_ESP32S2
  uint32_t val;
#else
  uint16_t val;
#endif
  esp_err_t err = touch_pad_get_thresh(pad, &val);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return Smi::from(static_cast<int>(val));
}

PRIMITIVE(set_threshold) {
  ARGS(IntResource, resource, uint16, threshold);
  touch_pad_t pad = static_cast<touch_pad_t>(resource->id());

  esp_err_t err = touch_pad_set_thresh(pad, threshold);
  if (err != ESP_OK) return Primitive::os_error(err, process);
  return process->program()->null_object();
}

} // namespace toit

#endif // defined(CONFIG_IDF_TARGET_ESP32) || defined(CONFIG_IDF_TARGET_ESP32S2) || defined(CONFIG_IDF_TARGET_ESP32S3)
