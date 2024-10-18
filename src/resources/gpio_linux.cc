// Copyright (C) 2024 Toitware ApS.
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

#ifdef TOIT_LINUX

#include <dirent.h>
#include <errno.h>
#include <gpiod.h>
#include <sys/stat.h>

#include "../objects_inline.h"
#include "../os.h"
#include "../primitive.h"
#include "../process.h"
#include "../resource.h"
#include "../resource_pool.h"
#include "../utils.h"
#include "../vm.h"

#include "../event_sources/epoll_linux.h"

namespace toit {

class GpioResourceGroup : public ResourceGroup {
 public:
  TAG(GpioResourceGroup);
  explicit GpioResourceGroup(Process* process)
      : ResourceGroup(process){}
  // TODO(florian): add event handling for the pin's file descriptors.
};

class GpioChipResource : public Resource {
 public:
  TAG(GpioChipResource);
  GpioChipResource(ResourceGroup* group, gpiod_chip* chip)
      : Resource(group)
      , chip_(chip){}

  ~GpioChipResource() override {
    gpiod_chip_close(chip_);
  }

  gpiod_chip* chip() { return chip_; }

 private:
  gpiod_chip* chip_;
};

class GpioPinResource : public Resource {
 public:
  TAG(GpioPinResource);
  GpioPinResource(ResourceGroup* group, int offset)
      : Resource(group)
      , offset_(offset){}

  ~GpioPinResource() override;

  int offset() { return offset_; }

  gpiod_line_settings* settings() { return settings_; }
  void replace_settings(gpiod_line_settings* settings) {
    if (settings == settings_) return;
    if (settings_ != null) gpiod_line_settings_free(settings_);
    settings_ = settings;
  }

  gpiod_line_request* request() { return request_; }
  void set_request(gpiod_line_request* request) { request_ = request; }

  Object* apply_and_store_settings(gpiod_line_settings* settings, Process* process);

 private:
  int offset_ = -1;
  gpiod_line_settings* settings_ = null;
  gpiod_line_request* request_ = null;
};

static int chip_filter(const struct dirent* entry) {
  char* path;

  if (asprintf(&path, "/dev/%s", entry->d_name) == -1) return 0;

  int result = false;
  struct stat sb;
  if ((lstat(path, &sb) == 0) &&
      (!S_ISLNK(sb.st_mode)) &&
      gpiod_is_gpiochip_device(path)) {
    result = true;
  }

  free(path);
  return result;
}

template<typename T> static void free_array(T* array, int count) {
  for (int i = 0; i < count; i++) {
    free(array[i]);
  }
  free(array);
}

static List<char*> find_all_chips() {
  struct dirent** entries;
  int num_chips = scandir("/dev/", &entries, chip_filter, versionsort);
  if (num_chips < 0) return List<char*>();

  char** paths = unvoid_cast<char**>(calloc(num_chips, sizeof(*paths)));

  for (int i = 0; i < num_chips; i++) {
    if (asprintf(&paths[i], "/dev/%s", entries[i]->d_name) == -1) {
      free_array(paths, i);
      free_array(entries, num_chips);
      return List<char*>();
    }
  }

  free_array(entries, num_chips);
  return List<char*>(paths, num_chips);
}

static void fill_settings(gpiod_line_settings* settings, bool pull_up, bool pull_down,
                          bool input, bool output, bool open_drain, int initial_value) {
  if (pull_up) gpiod_line_settings_set_bias(settings, GPIOD_LINE_BIAS_PULL_UP);
  if (pull_down) gpiod_line_settings_set_bias(settings, GPIOD_LINE_BIAS_PULL_DOWN);
  if (input && !pull_up && !pull_down) gpiod_line_settings_set_bias(settings, GPIOD_LINE_BIAS_DISABLED);
  if (input) gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_INPUT);
  if (output) gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_OUTPUT);
  if (open_drain) {
    gpiod_line_settings_set_drive(settings, GPIOD_LINE_DRIVE_OPEN_DRAIN);
  } else {
    gpiod_line_settings_set_drive(settings, GPIOD_LINE_DRIVE_PUSH_PULL);
  }
  auto output_value = initial_value == 0 ? GPIOD_LINE_VALUE_INACTIVE : GPIOD_LINE_VALUE_ACTIVE;
  gpiod_line_settings_set_output_value(settings, output_value);
}


GpioPinResource::~GpioPinResource() {
  if (settings_ != null) {
    fill_settings(settings_, false, false, true, false, false, 0);
    apply_and_store_settings(settings_, null);
    gpiod_line_settings_free(settings_);
  }
  if (request_ != null) gpiod_line_request_release(request_);
}

Object* GpioPinResource::apply_and_store_settings(gpiod_line_settings* settings, Process* process) {
  auto config = gpiod_line_config_new();
  if (config == null) {
    if (process == null) return null;
    FAIL(ALLOCATION_FAILED);
  }
  Defer free_config { [&] { gpiod_line_config_free(config); }};
  unsigned int offset = offset_;
  int ret = gpiod_line_config_add_line_settings(config, &offset, 1, settings);
  if (ret != 0) {
    if (process == null) return null;
    return Primitive::os_error(errno, process, "add line settings");
  }

  ret = gpiod_line_request_reconfigure_lines(request(), config);
  if (ret != 0) {
    if (process == null) return null;
    return Primitive::os_error(errno, process, "reconfigure the line");
  }
  replace_settings(settings);
  return null;
}

MODULE_IMPLEMENTATION(gpio_linux, MODULE_GPIO_LINUX);

PRIMITIVE(list_chips) {
  auto entries = find_all_chips();
  auto result = process->object_heap()->allocate_array(entries.length(), process->null_object());
  if (result == null) {
    free_array(entries.data(), entries.length());
    FAIL(ALLOCATION_FAILED);
  }
  for (int i = 0; i < entries.length(); i++) {
    auto str = process->allocate_string(entries[i]);
    if (str == null) {
      free_array(entries.data(), entries.length());
      FAIL(ALLOCATION_FAILED);
    }
    result->at_put(i, str);
  }
  free_array(entries.data(), entries.length());
  return result;
}

PRIMITIVE(chip_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new SimpleResourceGroup(process);
  if (!group) FAIL(MALLOC_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(chip_new) {
  ARGS(ResourceGroup, group, cstring, path)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto chip = gpiod_chip_open(path);
  if (chip == null) {
    return Primitive::os_error(errno, process, "open chip");
  }

  auto resource = _new GpioChipResource(group, chip);
  if (resource == null) {
    gpiod_chip_close(chip);
    FAIL(ALLOCATION_FAILED);
  }

  group->register_resource(resource);
  proxy->set_external_address(resource);
  return proxy;
}

PRIMITIVE(chip_close) {
  ARGS(GpioChipResource, chip)
  chip->resource_group()->unregister_resource(chip);
  chip_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(chip_info) {
  ARGS(GpioChipResource, resource)

  auto info = gpiod_chip_get_info(resource->chip());
  if (info == null) {
    return Primitive::os_error(errno, process, "get chip info");
  }
  Defer free_chip_info { [&] { gpiod_chip_info_free(info); }};

  const char* name_cstr = gpiod_chip_info_get_name(info);
  const char* label_cstr = gpiod_chip_info_get_label(info);
  int num_lines = gpiod_chip_info_get_num_lines(info);

  String* name = process->allocate_string(name_cstr);
  String* label = process->allocate_string(label_cstr);
  if (name == null || label == null) FAIL(ALLOCATION_FAILED);

  if (!Smi::is_valid(num_lines)) FAIL(OUT_OF_RANGE);

  auto result = process->object_heap()->allocate_array(3, process->null_object());
  result->at_put(0, name);
  result->at_put(1, label);
  result->at_put(2, Smi::from(num_lines));
  return result;
}

PRIMITIVE(chip_pin_info) {
  ARGS(GpioChipResource, resource, int, offset)

  auto chip = resource->chip();

  auto result = process->object_heap()->allocate_array(4, process->null_object());
  if (result == null) FAIL(ALLOCATION_FAILED);

  auto info = gpiod_chip_get_line_info(chip, offset);
  if (info == null) {
    return Primitive::os_error(errno, process, "get line info");
  }
  Defer free_info { [&] { gpiod_line_info_free(info); }};

  const char* name_cstr = gpiod_line_info_get_name(info);
  bool is_used = gpiod_line_info_is_used(info);
  bool is_input = gpiod_line_info_get_direction(info) == GPIOD_LINE_DIRECTION_INPUT;
  bool is_active_low = gpiod_line_info_is_active_low(info);

  Object* name;
  if (name_cstr == null) {
    name = process->null_object();
  } else {
    name = process->allocate_string(name_cstr);
    if (name == null) FAIL(ALLOCATION_FAILED);
  }

  result->at_put(0, name);
  result->at_put(1, BOOL(is_used));
  result->at_put(2, BOOL(is_input));
  result->at_put(3, BOOL(is_active_low));
  return result;
}

PRIMITIVE(chip_pin_offset_for_name) {
  ARGS(GpioChipResource, resource, cstring, name)

  auto offset = gpiod_chip_get_line_offset_from_name(resource->chip(), name);
  if (!Smi::is_valid(offset)) FAIL(OUT_OF_RANGE);
  return Smi::from(offset);
}

PRIMITIVE(pin_init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto group = _new GpioResourceGroup(process);
  if (group == null) FAIL(ALLOCATION_FAILED);

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(pin_new) {
  ARGS(GpioResourceGroup, group, GpioChipResource, chip,
       int, offset, bool, pull_up, bool, pull_down, bool, input,
       bool, output, bool, open_drain, int, initial_value)
  bool successful_return = false;

  if (input && output) FAIL(INVALID_ARGUMENT);
  if (pull_up && pull_down) FAIL(INVALID_ARGUMENT);

  auto pin_info = gpiod_chip_get_line_info(chip->chip(), offset);
  if (pin_info == null) return Primitive::os_error(errno, process, "get line info");
  bool is_used = gpiod_line_info_is_used(pin_info);
  gpiod_line_info_free(pin_info);
  if (is_used) FAIL(ALREADY_IN_USE);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  auto resource = _new GpioPinResource(group, offset);
  if (resource == null) FAIL(ALLOCATION_FAILED);

  // Note that the settings are stored in the resource and thus don't need to be freed here.
  auto settings = gpiod_line_settings_new();
  if (settings == null) FAIL(ALLOCATION_FAILED);
  Defer free_settings { [&] { if (!successful_return) gpiod_line_settings_free(settings); }};

  fill_settings(settings, pull_up, pull_down, input, output, open_drain, initial_value);

  auto line_config = gpiod_line_config_new();
  if (line_config == null) FAIL(ALLOCATION_FAILED);
  Defer free_config { [&] { gpiod_line_config_free(line_config); }};

  unsigned int unsigned_offset = offset;
  int ret = gpiod_line_config_add_line_settings(line_config, &unsigned_offset, 1, settings);
  if (ret != 0) {
    return Primitive::os_error(errno, process, "add line settings");
  }

  auto request_config = gpiod_request_config_new();
  if (request_config == null) FAIL(ALLOCATION_FAILED);
  Defer free_request_config { [&] { gpiod_request_config_free(request_config); }};

  gpiod_request_config_set_consumer(request_config, "toit");

  auto request = gpiod_chip_request_lines(chip->chip(), request_config, line_config);
  if (request == null) {
    return Primitive::os_error(errno, process, "request line");
  }

  resource->replace_settings(settings);
  resource->set_request(request);
  group->register_resource(resource);
  proxy->set_external_address(resource);

  successful_return = true;
  return proxy;
}

PRIMITIVE(pin_close) {
  ARGS(GpioPinResource, pin)
  pin->resource_group()->unregister_resource(pin);
  pin_proxy->clear_external_address();
  return process->null_object();
}

PRIMITIVE(pin_configure) {
  ARGS(GpioPinResource, pin, bool, pull_up, bool, pull_down, bool, input, bool, output, bool, open_drain, int, initial_value)
  bool successful_return = false;

  if (input && output) FAIL(INVALID_ARGUMENT);
  if (pull_up && pull_down) FAIL(INVALID_ARGUMENT);

  // Note that the settings are stored in the resource and thus don't need to be freed here.
  auto settings = gpiod_line_settings_new();
  if (settings == null) FAIL(ALLOCATION_FAILED);
  Defer free_settings { [&] { if (!successful_return) gpiod_line_settings_free(settings); }};

  fill_settings(settings, pull_up, pull_down, input, output, open_drain, initial_value);

  Object* error = pin->apply_and_store_settings(settings, process);
  if (error != null) return error;

  successful_return = true;
  return process->null_object();
}

PRIMITIVE(pin_get) {
  ARGS(GpioPinResource, pin)
  unsigned int offset = pin->offset();
  auto request = pin->request();
  if (request == null) FAIL(INVALID_ARGUMENT);

  int value = gpiod_line_request_get_value(request, offset);
  if (value == GPIOD_LINE_VALUE_ACTIVE) return Smi::from(1);
  if (value == GPIOD_LINE_VALUE_INACTIVE) return Smi::from(0);
  return Primitive::os_error(errno, process);
}

PRIMITIVE(pin_set) {
  ARGS(GpioPinResource, pin, int, value)
  unsigned int offset = pin->offset();
  auto request = pin->request();
  if (request == null) FAIL(INVALID_ARGUMENT);

  auto output = value == 0 ? GPIOD_LINE_VALUE_INACTIVE : GPIOD_LINE_VALUE_ACTIVE;
  int ret = gpiod_line_request_set_value(request, offset, output);
  if (ret != 0) {
    return Primitive::os_error(errno, process);
  }
  return process->null_object();
}

PRIMITIVE(pin_set_open_drain) {
  ARGS(GpioPinResource, pin, bool, open_drain)

  auto settings = pin->settings();
  if (settings == null) FAIL(INVALID_ARGUMENT);

  gpiod_line_settings_set_drive(settings, open_drain ? GPIOD_LINE_DRIVE_OPEN_DRAIN : GPIOD_LINE_DRIVE_PUSH_PULL);

  Object* error = pin->apply_and_store_settings(settings, process);
  if (error != null) return error;

  return process->null_object();
}

}  // namespace toit

#endif  // TOIT_LINUX
