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

#if defined(TOIT_LINUX) || defined(TOIT_BSD) || defined(TOIT_WINDOWS)

#include <unordered_map>
#include <string>
#include <vector>

#include "../resource.h"
#include "../objects_inline.h"
#include "../process.h"

namespace toit {

const size_t MAX_KEY_LENGTH_ = 15;
static std::unordered_map<std::string, int32_t> persistent_int32_map;
static std::unordered_map<std::string, int64_t> persistent_int64_map;
static std::unordered_map<std::string, std::vector<uint8_t>> persistent_bytes_map;

class PersistentResourceGroup : public ResourceGroup {
 public:
  TAG(PersistentResourceGroup);
  explicit PersistentResourceGroup(Process* process)
      : ResourceGroup(process, null) {}

  ~PersistentResourceGroup() {}
};

bool is_valid_key(const char* key, Process* process) {
  if (key[0] == '\0' || strlen(key) > MAX_KEY_LENGTH_) return false;
  if (!process->is_privileged() && key[0] == '_') return false;
  return true;
}

MODULE_IMPLEMENTATION(flash_kv, MODULE_FLASH_KV)

PRIMITIVE(init) {
  ARGS(cstring, partition, cstring, name, bool, read_only)
  USE(partition);
  USE(name);
  USE(read_only);
  // TODO: We should find a way to honor these properties.

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  PersistentResourceGroup* resource_group = _new PersistentResourceGroup(process);
  if (!resource_group) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(read_bytes) {
  ARGS(PersistentResourceGroup, resource_group, cstring, key);
  USE(resource_group);
  if (!is_valid_key(key, process)) INVALID_ARGUMENT;

  std::string str(key);
  auto it = persistent_bytes_map.find(str);
  if (it == persistent_bytes_map.end()) {
    return process->program()->null_object();
  }

  ByteArray* array = process->allocate_byte_array(it->second.size());
  if (array == null) ALLOCATION_FAILED;

  ByteArray::Bytes bytes(array);
  memmove(bytes.address(), it->second.data(), bytes.length());
  return array;
}

PRIMITIVE(write_bytes) {
  ARGS(PersistentResourceGroup, resource_group, cstring, key, ByteArray, value);
  USE(resource_group);
  if (!is_valid_key(key, process)) INVALID_ARGUMENT;

  std::string str(key);
  ByteArray::Bytes bytes(value);
  AllowThrowingNew host_only;
  std::vector<uint8_t> data(bytes.address(), bytes.address() + bytes.length());
  persistent_bytes_map[str] = data;

  return process->program()->null_object();
}

PRIMITIVE(delete) {
  ARGS(PersistentResourceGroup, resource_group, cstring, key);
  USE(resource_group);

  if (!is_valid_key(key, process)) INVALID_ARGUMENT;

  std::string str(key);
  AllowThrowingNew host_only;
  persistent_int32_map.erase(str);
  persistent_int64_map.erase(str);
  persistent_bytes_map.erase(str);

  return process->program()->null_object();
}

PRIMITIVE(erase) {
  ARGS(String, name);
  USE(name);

  persistent_int32_map.clear();
  persistent_int64_map.clear();
  persistent_bytes_map.clear();

  return process->program()->null_object();
}

} // namespace toit

#endif
