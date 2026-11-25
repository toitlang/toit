// Copyright (C) 2019 Toitware ApS.
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

#pragma once

#include "linked.h"
#include "utils.h"
#include "uuid.h"

namespace toit {

// Keep in sync with system/flash/allocation.toit.
static const uint8 FLASH_ALLOCATION_TYPE_PROGRAM = 0;
static const uint8 FLASH_ALLOCATION_TYPE_REGION = 1;

static const int FLASH_PAGE_SIZE_LOG2 = 12;
static const int FLASH_PAGE_SIZE = 1 << FLASH_PAGE_SIZE_LOG2;
static const int FLASH_SEGMENT_SIZE = 16;

class FlashAllocation {
 public:
  class __attribute__ ((__packed__)) Header {
   public:
    static const uint8  FORMAT_VERSION = 0;
    static const uint32 FORMAT_MARKER  = 0xdeadface;

    static const int FLAGS_PROGRAM_HAS_ASSETS_MASK = 1 << 7;
    // Containers from images with this flag always run untrusted
    // (ContainerService.FLAG-UNTRUSTED in lib/system/api/containers.toit).
    static const int FLAGS_PROGRAM_UNTRUSTED_MASK = 1 << 2;
    // The install-time verdict (Phase 5), set only by the VM: the program
    // of an image flagged untrusted was accepted by the format-2 verifier
    // with the untrusted rules when it was committed to flash
    // (primitive flash_registry.allocate). The header checksum of such an
    // allocation also covers the program's bytes (compute_checksum), so the
    // verdict holds exactly for the bytes it was computed on: if they
    // change, the allocation is no longer valid.
    // The verdict holds for the checks that computed it: the header of such
    // an allocation records the verification epoch of the VM that set the
    // bit (verification_epoch()) in the last EPOCH_SIZE bytes of uuid_,
    // where other allocations repeat the system uuid; only the first
    // UUID_SIZE - EPOCH_SIZE bytes of the system uuid are compared then
    // (is_valid). The checksum covers the epoch as every other header byte.
    // A verdict of another epoch is no verdict (program_verified).
    static const int FLAGS_PROGRAM_VERIFIED_MASK = 1 << 6;
    static const unsigned EPOCH_SIZE = 4;
    static const unsigned ID_SIZE = UUID_SIZE;
    static const unsigned METADATA_SIZE = 5;  // Picked for 16 byte alignment.

    Header(const void* memory, uint8 type, const uint8* id, word size, const uint8* metadata);

    const uint8* id() const { return id_; }
    word size() const { return size_in_pages_ << FLASH_PAGE_SIZE_LOG2; }

   private:
    // Data section for the header.
    uint32 marker_;  // Magic marker.
    uint32 checksum_;
    uint8 id_[ID_SIZE];
    uint8 metadata_[METADATA_SIZE];
    uint8 type_;
    uint16 size_in_pages_;
    uint8 uuid_[UUID_SIZE];

    bool is_valid(bool embedded) const;
    // Whether the header carries the verdict bit (and so an epoch).
    bool has_verdict_bit() const {
      return type_ == FLASH_ALLOCATION_TYPE_PROGRAM && (metadata_[0] & FLAGS_PROGRAM_VERIFIED_MASK) != 0;
    }
    uint8 type() const { return type_; }
    const uint8* metadata() const { return metadata_; }
    uint32 compute_checksum(const void* memory) const;

    friend class FlashAllocation;
  };

  // Type tests.
  bool is_program() const { return type() == FLASH_ALLOCATION_TYPE_PROGRAM; }
  bool is_region() const { return type() == FLASH_ALLOCATION_TYPE_REGION; }

  // Simple accessors.
  word size_no_assets() const { return header_.size(); }
  uint8 type() const { return header_.type(); }
  const uint8* id() const { return header_.id(); }
  const uint8* metadata() const { return header_.metadata(); }

  // Get the full size of the allocation. For programs, this includes the assets.
  word size() const;

  // Check if the allocation is valid.
  bool is_valid() const { return header_.is_valid(false); }
  bool is_valid_embedded() const { return header_.is_valid(true); }

  // Commit an allocation by providing it with the correct header. Returns
  // whether the allocation is valid after the commit.
  // Includes the virtual memory address of the allocation in the checksum
  // just in case the flash is mapped at an incompatible address.
  static bool commit(const void* memory, word size, const Header* header);

  // Get the flags encoded in the first metadata byte. Only valid for programs.
  int program_flags() const { ASSERT(is_program()); return header_.metadata()[0]; }

  // Returns whether the program has appended assets.
  bool program_has_assets() const {
    return (program_flags() & Header::FLAGS_PROGRAM_HAS_ASSETS_MASK) != 0;
  }

  // Whether containers from this image always run untrusted.
  bool program_untrusted() const {
    return (program_flags() & Header::FLAGS_PROGRAM_UNTRUSTED_MASK) != 0;
  }

  // Whether the program carries an install-time verdict of the current
  // verification epoch (see Header::FLAGS_PROGRAM_VERIFIED_MASK). A verdict
  // recorded with another epoch (by a firmware whose install-time checks
  // differ) is no verdict. Meaningful for a valid allocation only: validity
  // checks the bytes the verdict is bound to.
  bool program_verified() const;

  // Whether the program has the verdict bit, of whatever epoch (for the
  // message when program_verified() is false).
  bool program_has_verdict_bit() const { return header_.has_verdict_bit(); }

  // The verification epoch recorded with the verdict bit (if
  // program_has_verdict_bit()).
  uint32 program_verdict_epoch() const;

  // The verification epoch of this VM: it identifies the install-time
  // checks and the interpreter contract they establish. Computed at build
  // time from the sources that define them (verified/verification-epoch.cmake).
  static uint32 verification_epoch();

  // Get the total size of the appended program assets if any.
  int program_assets_size(uint8** bytes, word* length) const;

  // The trailing certificate block of a program image (format 2 note 18,
  // verified/spec/format/18-shipped-certificate.md): right after the
  // allocation (program and padded assets), page aligned,
  //   u32 marker "TCB1"   u32 length   certificate   padding to a page.
  // The marker is larger than any assets length, so a block right after the
  // program is told apart from assets. The block is not part of the
  // allocation: the installer verifies the program with it before the
  // header is written and then erases its pages.
  static const uint32 CERTIFICATE_BLOCK_MARKER = 0x31424354;  // "TCB1".

  // Finds the certificate block at [block] if the bytes up to [limit] hold
  // one: sets [certificate] and [length] to the certificate's bytes and
  // returns true. Every read stays below [limit].
  static bool find_certificate_block(const void* block, const void* limit,
                                     const uint8** certificate, word* length);

  // The size of a program image's allocation with its assets, from the
  // program's size (page aligned, the header's size) and the image bytes
  // at [memory] up to [limit] (the reservation): the assets, if the image
  // has some, follow the program as a u32 length and the bytes, padded to
  // a page. Sets [has_assets]. Returns -1 if the assets do not fit.
  static word image_allocation_size(const void* memory, word program_size, const void* limit,
                                    bool* has_assets);

 protected:
  FlashAllocation(const uint8* id, word size) : header_(0, FLASH_ALLOCATION_TYPE_PROGRAM, id, size, null) {}

 private:
  Header header_;
};

class Reservation;
typedef LinkedList<Reservation> ReservationList;
class Reservation : public ReservationList::Element {
 public:
  Reservation(word offset, word size) : offset_(offset), size_(size) {}

  word left() const { return offset_; }
  word right() const { return offset_ + size_; }
  word size() const { return size_; }

 private:
  word offset_;
  word size_;
};

class RegionGrant;
typedef LinkedList<RegionGrant> RegionGrantList;
class RegionGrant : public RegionGrantList::Element {
 public:
  RegionGrant(int client, int handle, uword offset, uword size, bool writable)
      : client_(client), handle_(handle), offset_(offset), size_(size), writable_(writable) {}

  int client() const { return client_; }
  int handle() const { return handle_; }
  uword offset() const { return offset_; }
  uword size() const { return size_; }
  bool writable() const { return writable_; }

 private:
  int client_;
  int handle_;
  uword offset_;
  uword size_;
  bool writable_;
};

} // namespace toit
