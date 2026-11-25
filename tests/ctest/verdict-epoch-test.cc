// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The binding of the install-time verdict to the verification epoch
// (src/flash_allocation.h, FLAGS_PROGRAM_VERIFIED_MASK;
// verified/verification-epoch.cmake): a header with the verdict bit records
// the epoch of the VM that wrote it in the last four bytes of its uuid
// field, under the header checksum.
//
//   * A verdict of this VM's epoch is a verdict (program_verified).
//   * A verdict of another epoch, in a header that is otherwise exactly what
//     a firmware with that epoch writes, is valid (listed) but no verdict.
//   * The epoch cannot be edited in place: without a new checksum the
//     allocation is invalid.
//   * Headers without the verdict bit, region headers and embedded program
//     headers (checksum 0) keep comparing the whole system uuid; an embedded
//     program never has a verdict.
//   * The epoch compiled into the VM is the one the build computed from the
//     sources (EXPECTED_VERIFICATION_EPOCH, tests/ctest/CMakeLists.txt).

#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "../../src/top.h"
#include "../../src/embedded_data.h"
#include "../../src/flash_allocation.h"
#include "../../src/utils.h"

namespace toit {

static int failures = 0;

#define EXPECT(condition) do { \
  if (!(condition)) { printf("FAIL (line %d): %s\n", __LINE__, #condition); failures++; } \
} while (false)

static const word PAGES = 2;
static const word SIZE = PAGES * FLASH_PAGE_SIZE;
static const unsigned EPOCH_OFFSET = UUID_SIZE - FlashAllocation::Header::EPOCH_SIZE;

static const uint8 ID[UUID_SIZE] = {
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
};

static const int UNTRUSTED = FlashAllocation::Header::FLAGS_PROGRAM_UNTRUSTED_MASK;
static const int VERIFIED = FlashAllocation::Header::FLAGS_PROGRAM_VERIFIED_MASK;

// Page-aligned memory for one allocation, its bytes after the header set to
// a pattern (the "program").
static uint8* fresh_memory() {
  void* memory = mmap(null, SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (memory == MAP_FAILED) FATAL("mmap");
  uint8* bytes = static_cast<uint8*>(memory);
  for (word i = 0; i < SIZE; i++) bytes[i] = static_cast<uint8>(i * 7 + 3);
  return bytes;
}

// Writes the header the VM writes when it commits an allocation with
// [flags] (as the commit primitives do after install_verdict).
static FlashAllocation* commit(uint8* memory, uint8 type, int flags) {
  uint8 metadata[FlashAllocation::Header::METADATA_SIZE] = { static_cast<uint8>(flags), 1, 2, 3, 4 };
  FlashAllocation::Header header(memory, type, ID, SIZE, metadata);
  memcpy(memory, &header, sizeof(header));
  return reinterpret_cast<FlashAllocation*>(memory);
}

static uint8* uuid_field(FlashAllocation* allocation) {
  return reinterpret_cast<uint8*>(allocation) + offsetof(FlashAllocation::Header, uuid_);
}

static uint32 recorded_epoch(FlashAllocation* allocation) {
  return Utils::read_unaligned_uint32_le(uuid_field(allocation) + EPOCH_OFFSET);
}

// The header a firmware with the verification epoch [epoch] writes for the
// same allocation: the epoch and the checksum over it.
static void rewrite_epoch(FlashAllocation* allocation, uint32 epoch) {
  Utils::write_unaligned_uint32_le(uuid_field(allocation) + EPOCH_OFFSET, epoch);
  allocation->header_.checksum_ = allocation->header_.compute_checksum(allocation);
}

static void test_current_epoch() {
  EXPECT(FlashAllocation::verification_epoch() == EXPECTED_VERIFICATION_EPOCH);
  FlashAllocation* allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, UNTRUSTED | VERIFIED);
  EXPECT(allocation->is_valid());
  EXPECT(allocation->program_untrusted());
  EXPECT(allocation->program_has_verdict_bit());
  EXPECT(allocation->program_verified());
  EXPECT(allocation->program_verdict_epoch() == FlashAllocation::verification_epoch());
  EXPECT(recorded_epoch(allocation) == FlashAllocation::verification_epoch());
  // The rest of the uuid field is the system uuid.
  EXPECT(memcmp(uuid_field(allocation), EmbeddedData::uuid(), EPOCH_OFFSET) == 0);
  // The metadata is as given (the epoch takes no metadata byte).
  EXPECT(allocation->metadata()[1] == 1 && allocation->metadata()[4] == 4);
}

static void test_other_epoch() {
  uint32 current = FlashAllocation::verification_epoch();
  FlashAllocation* allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, UNTRUSTED | VERIFIED);
  uint32 others[] = { current ^ 1, current ^ 0x80000000u, current + 1, 0, 0xffffffffu };
  for (uint32 other : others) {
    if (other == current) continue;
    rewrite_epoch(allocation, other);
    // Valid (listed, as an image without a verdict is), but no verdict.
    EXPECT(allocation->is_valid());
    EXPECT(allocation->program_has_verdict_bit());
    EXPECT(!allocation->program_verified());
    EXPECT(allocation->program_verdict_epoch() == other);
  }
  // The decision is the epoch alone: with the current epoch it is a verdict
  // again.
  rewrite_epoch(allocation, current);
  EXPECT(allocation->is_valid());
  EXPECT(allocation->program_verified());
}

static void test_epoch_not_editable() {
  uint32 current = FlashAllocation::verification_epoch();
  for (unsigned byte = 0; byte < FlashAllocation::Header::EPOCH_SIZE; byte++) {
    for (int bit = 0; bit < 8; bit++) {
      FlashAllocation* allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, UNTRUSTED | VERIFIED);
      uuid_field(allocation)[EPOCH_OFFSET + byte] ^= 1 << bit;
      // The checksum covers the epoch: the allocation is no longer valid
      // (not listed, never started).
      EXPECT(!allocation->is_valid());
      uuid_field(allocation)[EPOCH_OFFSET + byte] ^= 1 << bit;
      EXPECT(allocation->is_valid());
      EXPECT(allocation->program_verdict_epoch() == current);
      munmap(allocation, SIZE);
    }
  }
  // The program's bytes stay bound to the verdict.
  FlashAllocation* allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, UNTRUSTED | VERIFIED);
  reinterpret_cast<uint8*>(allocation)[SIZE - 1] ^= 0x20;
  EXPECT(!allocation->is_valid());
}

static void test_system_uuid_still_checked() {
  // A verdict header from a firmware with another system uuid (its first
  // twelve bytes differ) is not valid, whatever the epoch.
  FlashAllocation* allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, UNTRUSTED | VERIFIED);
  uuid_field(allocation)[0] ^= 1;
  rewrite_epoch(allocation, FlashAllocation::verification_epoch());
  EXPECT(!allocation->is_valid());
  allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, UNTRUSTED | VERIFIED);
  uuid_field(allocation)[EPOCH_OFFSET - 1] ^= 1;
  rewrite_epoch(allocation, FlashAllocation::verification_epoch());
  EXPECT(!allocation->is_valid());
}

static void test_without_verdict() {
  // Untrusted without the verdict bit (as install_verdict leaves a format-1
  // image under -Xuntrusted_format1), and trusted: the whole system uuid,
  // no epoch, no verdict.
  int flag_sets[] = { UNTRUSTED, 0 };
  for (int flags : flag_sets) {
    FlashAllocation* allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, flags);
    EXPECT(allocation->is_valid());
    EXPECT(!allocation->program_has_verdict_bit());
    EXPECT(!allocation->program_verified());
    EXPECT(memcmp(uuid_field(allocation), EmbeddedData::uuid(), UUID_SIZE) == 0);
    // The last bytes of the uuid are compared too.
    rewrite_epoch(allocation, FlashAllocation::verification_epoch());
    EXPECT(!allocation->is_valid());
  }
  // A region's header is unchanged (its uuid is the data uuid).
  FlashAllocation* region = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_REGION, 0xff);
  EXPECT(region->is_valid());
  EXPECT(region->is_region());
}

static void test_embedded() {
  // A program embedded in the firmware (checksum 0, its header from the
  // firmware's build, never from install_verdict) has no verdict, even
  // with both bits set.
  FlashAllocation* allocation = commit(fresh_memory(), FLASH_ALLOCATION_TYPE_PROGRAM, UNTRUSTED);
  allocation->header_.metadata_[0] |= VERIFIED;
  allocation->header_.checksum_ = 0;
  EXPECT(allocation->is_valid_embedded());
  EXPECT(!allocation->program_verified());
  // With this VM's epoch in place of the uuid's last bytes it is not even
  // valid: embedded headers compare the whole system uuid.
  Utils::write_unaligned_uint32_le(uuid_field(allocation) + EPOCH_OFFSET, FlashAllocation::verification_epoch());
  if (memcmp(uuid_field(allocation), EmbeddedData::uuid(), UUID_SIZE) != 0) {
    EXPECT(!allocation->is_valid_embedded());
  }
  EXPECT(!allocation->program_verified());
}

}  // namespace toit

int main(int argc, char** argv) {
  toit::test_current_epoch();
  toit::test_other_epoch();
  toit::test_epoch_not_editable();
  toit::test_system_uuid_still_checked();
  toit::test_without_verdict();
  toit::test_embedded();
  if (toit::failures != 0) {
    printf("%d failures\n", toit::failures);
    return 1;
  }
  printf("verdict-epoch-test OK (epoch %08x)\n", static_cast<unsigned>(toit::FlashAllocation::verification_epoch()));
  return 0;
}
