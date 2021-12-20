// Copyright (C) 2018 Toitware ApS. All rights reserved.

#include "../top.h"

#if defined(TOIT_LINUX) || defined(TOIT_BSD)

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

  ~PersistentResourceGroup() {
  }
};

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

  std::string str(key);
  if (str.length() > MAX_KEY_LENGTH_) INVALID_ARGUMENT;
  auto it = persistent_bytes_map.find(str);
  if (it == persistent_bytes_map.end()) {
    return process->program()->null_object();
  }

  Error* error = null;
  ByteArray* array = process->allocate_byte_array(it->second.size(), &error);
  if (array == null) return error;

  ByteArray::Bytes bytes(array);
  memmove(bytes.address(), it->second.data(), bytes.length());
  return array;
}

PRIMITIVE(write_bytes) {
  ARGS(PersistentResourceGroup, resource_group, cstring, key, ByteArray, value);
  USE(resource_group);
  std::string str(key);
  if (str.length() > MAX_KEY_LENGTH_) INVALID_ARGUMENT;
  ByteArray::Bytes bytes(value);
  AllowThrowingNew unix_only;
  std::vector<uint8_t> data(bytes.address(), bytes.address() + bytes.length());
  persistent_bytes_map[str] = data;

  return process->program()->null_object();
}

PRIMITIVE(delete) {
  ARGS(PersistentResourceGroup, resource_group, String, key);
  USE(resource_group);

  if (key->length() > static_cast<int>(MAX_KEY_LENGTH_)) INVALID_ARGUMENT;
  String::Bytes bytes(key);
  std::string str(char_cast(bytes.address()), bytes.length());
  AllowThrowingNew unix_only;
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
