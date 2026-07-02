// Copyright (C) 2022 Toitware ApS.
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

#include "embedded_data.h"
#include "entropy_mixer.h"
#include "uuid.h"

namespace toit {

#ifdef TOIT_ESP32
extern "C" int _rodata_reserved_end;
#endif

#ifdef TOIT_EC618
extern "C" {
  #include "mem_map.h"
}
#endif

const EmbeddedDataExtension* EmbeddedDataExtension::cast(const void* pointer) {
  const uint32* header = reinterpret_cast<const uint32*>(pointer);
  if (!header) return null;
  if (header[HEADER_INDEX_MARKER] != HEADER_MARKER) return null;
  uint32 checksum = 0;
  for (int i = 0; i < HEADER_WORDS; i++) checksum ^= header[i];
  if (checksum != HEADER_CHECKSUM) return null;
#ifdef TOIT_ESP32
  uint32 size = header[HEADER_INDEX_USED] + header[HEADER_INDEX_FREE];
  void* end = reinterpret_cast<void*>(reinterpret_cast<uint32>(pointer) + size);
  if (end > &_rodata_reserved_end) FATAL("rodata reservation too small");
#elif defined(TOIT_EC618)
  // On EC618, the free field is not used: the config data is written
  // immediately after the "used" area, and the header still validates
  // its own checksum without referring to free. A non-zero free here
  // means we're not looking at a Toit-produced extension; reject it so
  // config() doesn't dereference whatever happens to sit at
  // header + used.
  if (header[HEADER_INDEX_FREE] != 0) return null;
#endif
  return reinterpret_cast<const EmbeddedDataExtension*>(header);
}

int EmbeddedDataExtension::images() const {
  const uint32* header = reinterpret_cast<const uint32*>(this);
  return header[HEADER_INDEX_IMAGE_COUNT];
}

EmbeddedImage EmbeddedDataExtension::image(int n) const {
  ASSERT(n >= 0 && n < images());
  const uint32* header = reinterpret_cast<const uint32*>(this);
  const uword* table = reinterpret_cast<const uword*>(&header[HEADER_WORDS]);
  return EmbeddedImage{
    .program = reinterpret_cast<const Program*>(table[n * 2]),
    .size    = table[n * 2 + 1]
  };
}

List<uint8> EmbeddedDataExtension::config() const {
  // The config section is in the free area of the extension. We
  // decode the header to find the start and size of the free area.
  const uint32* header = reinterpret_cast<const uint32*>(this);
  uint32 used = header[HEADER_INDEX_USED];
#ifdef TOIT_EC618
  // On EC618, the free field is not used. The config data immediately
  // follows the used area and starts with a size encoding.
  uword address = reinterpret_cast<uword>(header) + used;
  uword size = *reinterpret_cast<const uint32*>(address);
  if (size == 0 || size == 0xffffffff) return List<uint8>();
  // Clamp size against the end of the AP image region. Without this,
  // a garbage size at header+used would let the caller (e.g.,
  // firmware_map) return a proxy that walks out of the addressable
  // flash window.
  uword image_end = AP_FLASH_LOAD_ADDR + AP_FLASH_LOAD_SIZE;
  uword config_start = address + sizeof(uint32);
  if (config_start >= image_end) return List<uint8>();
  uword max_size = image_end - config_start;
  if (size > max_size) return List<uint8>();
  uint8* data = reinterpret_cast<uint8*>(config_start);
  return List<uint8>(data, size);
#else
  uint32 free = header[HEADER_INDEX_FREE];
  // The config section is supposed to start with an encoding
  // of the size of the config. Make sure the free area is big
  // enough for that before looking at it.
  if (free < sizeof(uint32)) return List<uint8>();
  uword address = reinterpret_cast<uword>(header) + used;
  uword size = *reinterpret_cast<const uint32*>(address);
  uint8* data = reinterpret_cast<uint8*>(address + sizeof(uint32));
  return List<uint8>(data, Utils::min(size, (uword)(free - sizeof(uint32))));
#endif
}

uword EmbeddedDataExtension::total_size() const {
  const uint32* header = reinterpret_cast<const uint32*>(this);
  return header[HEADER_INDEX_USED] + header[HEADER_INDEX_FREE];
}

uword EmbeddedDataExtension::offset(const Program* program) const {
  return reinterpret_cast<uword>(program) - reinterpret_cast<uword>(this);
}

const Program* EmbeddedDataExtension::program(uword offset) const {
  return reinterpret_cast<const Program*>(reinterpret_cast<uword>(this) + offset);
}

#if defined(TOIT_ESP32) || defined(TOIT_EC618)

struct DromData {
  // The data between magic1 and magic2 must be less than 256 bytes, otherwise the
  // patching utility will not detect it. If the format is changed, the code in
  // tools/firmware.toit must be adapted and the ENVELOPE_FORMAT_VERSION bumped.
  uint32 magic1 = 0x7017da7a;  // "toitdata"
  uint32 extension = 0;
  uint8  uuid[UUID_SIZE] = { 0, };
  uint32 magic2 = 0x00c09f19;  // "config"
} __attribute__((packed));

// Note, you can't declare this const because then the compiler thinks it can
// just const propagate, but we are going to patch this before we flash it, so
// we don't want that.  But it's still const because it goes in a flash section.
#ifdef TOIT_ESP32
DromData drom_data __attribute__((section(".rodata_custom_desc")));
#else
DromData drom_data __attribute__((section(".rodata")));
#endif

const uint8* EmbeddedData::uuid() {
  return drom_data.uuid;
}

const EmbeddedDataExtension* EmbeddedData::extension() {
  return EmbeddedDataExtension::cast(reinterpret_cast<const void*>(drom_data.extension));
}

#else

const uint8* EmbeddedData::uuid() {
  static uint8* uuid = null;
  if (uuid) return uuid;

  const char* path = getenv("TOIT_FLASH_UUID_FILE");
  if (path == null) {
    // Host "devices" that aren't passed a file for their uuid get a non-unique
    // uuid which makes their support for OTAs, etc. limited.
    static uint8 non_unique_uuid[UUID_SIZE] = {
        0xe3, 0xbb, 0xa6, 0xa1, 0x23, 0x0c, 0x44, 0xa5,
        0x9f, 0x5d, 0x09, 0x0c, 0xf7, 0xfd, 0x15, 0x2a };
    uuid = non_unique_uuid;
    return uuid;
  }

  uuid = unvoid_cast<uint8*>(malloc(UUID_SIZE));

  FILE* file = fopen(path, "r");
  if (file != null) {
    bool success = fread(uuid, UUID_SIZE, 1, file) == 1;
    fclose(file);
    if (success) return uuid;
  }

  EntropyMixer::instance()->get_entropy(uuid, UUID_SIZE);
  file = fopen(path, "w");
  if (file == null) {
    perror("OS::image_uuid/fopen");
  }
  if (fwrite(uuid, UUID_SIZE, 1, file) != 1) {
    fprintf(stderr, "OS::image_uuid/fwrite failed: %s\n", strerror(ferror(file)));
  }
  fclose(file);
  return uuid;
}

const EmbeddedDataExtension* EmbeddedData::extension() {
  return null;
}

#endif

}  // namespace toit
