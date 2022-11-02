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

#if defined(TOIT_FREERTOS)

#include <nvs_flash.h>

#include "../resource.h"
#include "../objects_inline.h"
#include "../process.h"

namespace toit {
const size_t MAX_KEY_LENGTH_ = 15;
class PersistentResourceGroup : public ResourceGroup {
 public:
  TAG(PersistentResourceGroup);
  PersistentResourceGroup(nvs_handle handle, Process* process)
      : ResourceGroup(process, null)
      , handle_(handle) {}

  ~PersistentResourceGroup() {
    nvs_close(handle_);
  }

  nvs_handle handle() { return handle_; }

 private:
  nvs_handle handle_;
};

bool is_valid_key(const char* key, Process* process) {
  if (key[0] == '\0' || strlen(key) > MAX_KEY_LENGTH_) return false;
  if (!process->is_privileged() && key[0] == '_') return false;
  return true;
}

MODULE_IMPLEMENTATION(flash_kv, MODULE_FLASH_KV)

PRIMITIVE(init) {
  ARGS(cstring, partition, cstring, name, bool, read_only)
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  AllowThrowingNew issue_961;

  esp_err_t err = nvs_flash_init_partition(partition);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  nvs_handle handle;
  err = nvs_open_from_partition(partition, name, read_only ? NVS_READONLY : NVS_READWRITE, &handle);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  PersistentResourceGroup* resource_group = _new PersistentResourceGroup(handle, process);
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(read_bytes) {
  ARGS(PersistentResourceGroup, resource_group, cstring, key);
  if (!is_valid_key(key, process)) INVALID_ARGUMENT;
  size_t length;
  esp_err_t err = nvs_get_blob(resource_group->handle(), key, null, &length);
  if (err == ESP_ERR_NVS_NOT_FOUND) {
    return process->program()->null_object();
  } else if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  ByteArray* array = process->allocate_byte_array(length);
  if (array == null) ALLOCATION_FAILED;

  ByteArray::Bytes bytes(array);
  err = nvs_get_blob(resource_group->handle(), key, bytes.address(), &length);
  if (err == ESP_ERR_NVS_NOT_FOUND) {
    return process->program()->null_object();
  } else if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return array;
}

PRIMITIVE(write_bytes) {
  ARGS(PersistentResourceGroup, resource_group, cstring, key, ByteArray, value);
  if (!is_valid_key(key, process)) INVALID_ARGUMENT;
  // The NVS code does not check for malloc failure.  See
  // https://github.com/toitware/toit/issues/961
  AllowThrowingNew issue_961;

  ByteArray::Bytes bytes(value);

  esp_err_t err = nvs_set_blob(resource_group->handle(), key, bytes.address(), bytes.length());
  if (err != ESP_OK) return Primitive::os_error(err, process);

  err = nvs_commit(resource_group->handle());
  if (err != ESP_OK) return Primitive::os_error(err, process);

  return process->program()->null_object();
}

PRIMITIVE(delete) {
  ARGS(PersistentResourceGroup, resource_group, cstring, key);
  if (!is_valid_key(key, process)) INVALID_ARGUMENT;
  esp_err_t err = nvs_erase_key(resource_group->handle(), key);
  if (err == ESP_OK) {
    err = nvs_commit(resource_group->handle());
    if (err != ESP_OK) return Primitive::os_error(err, process);
  } else if (err != ESP_ERR_NVS_NOT_FOUND) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

PRIMITIVE(erase) {
  ARGS(cstring, name);

  esp_err_t err = nvs_flash_erase_partition(name);
  if (err != ESP_OK) {
    return Primitive::os_error(err, process);
  }

  return process->program()->null_object();
}

} // namespace toit

#endif
