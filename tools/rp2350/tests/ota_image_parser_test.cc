// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#include <stdint.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "ota_image_rp2350.h"
#include "boot/picobin.h"

namespace {

using toit::rp2350::ImageHash;
using toit::rp2350::parse_ota_image;

[[noreturn]] void fail(const char* message) {
  std::fprintf(stderr, "FAIL: %s\n", message);
  std::exit(1);
}

std::vector<uint8_t> read_file(const char* path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) fail("cannot open input image");
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(input), {});
}

uint32_t get_word(const std::vector<uint8_t>& bytes, size_t offset) {
  if (offset > bytes.size() || bytes.size() - offset < 4) fail("test read out of range");
  return uint32_t(bytes[offset]) | (uint32_t(bytes[offset + 1]) << 8) |
      (uint32_t(bytes[offset + 2]) << 16) |
      (uint32_t(bytes[offset + 3]) << 24);
}

void put_word(std::vector<uint8_t>* bytes, size_t offset, uint32_t value) {
  if (offset > bytes->size() || bytes->size() - offset < 4) fail("test write out of range");
  (*bytes)[offset] = value;
  (*bytes)[offset + 1] = value >> 8;
  (*bytes)[offset + 2] = value >> 16;
  (*bytes)[offset + 3] = value >> 24;
}

bool parse(const std::vector<uint8_t>& bytes, ImageHash* hash = nullptr,
           const uint8_t* first_sector = nullptr) {
  ImageHash local = {};
  return parse_ota_image(bytes.data(), bytes.size(),
                         hash == nullptr ? &local : hash, first_sector);
}

void expect_parse(const std::vector<uint8_t>& bytes, bool expected,
                  const char* description) {
  if (parse(bytes) != expected) {
    std::fprintf(stderr, "FAIL: mutation '%s' was unexpectedly %s\n",
                 description, expected ? "rejected" : "accepted");
    std::exit(1);
  }
}

uint32_t find_root(const std::vector<uint8_t>& bytes) {
  if (bytes.size() < 4096) fail("canonical image is too short");
  uint32_t root = UINT32_MAX;
  for (uint32_t offset = 0; offset < 4096; offset += 4) {
    if (get_word(bytes, offset) != PICOBIN_BLOCK_MARKER_START) continue;
    if (root != UINT32_MAX) fail("canonical image has multiple scan-window markers");
    root = offset;
  }
  if (root == UINT32_MAX) fail("canonical image has no scan-window marker");
  return root;
}

std::vector<uint8_t> changed_word(const std::vector<uint8_t>& input,
                                  size_t offset, uint32_t value) {
  std::vector<uint8_t> result = input;
  put_word(&result, offset, value);
  return result;
}

void run_regressions(const std::vector<uint8_t>& image) {
  ImageHash hash = {};
  if (!parse(image, &hash)) fail("canonical SDK image was rejected");
  if (hash.range_count < 2 || hash.ranges[0].offset != 0) {
    fail("canonical image has an unexpected load-map shape");
  }
  uint32_t covered = 0;
  uint32_t zero_gap_offset = UINT32_MAX;
  for (unsigned i = 0; i < hash.range_count; i++) {
    if (hash.ranges[i].size == 0 || hash.ranges[i].offset < covered ||
        hash.ranges[i].offset > hash.block_offset ||
        hash.ranges[i].size > hash.block_offset - hash.ranges[i].offset) {
      fail("canonical load-map ranges overlap or cross metadata");
    }
    for (uint32_t at = covered; at < hash.ranges[i].offset; at++) {
      if (image[at] != 0) fail("canonical un-hashed load-map gap is not zero");
    }
    if (covered != hash.ranges[i].offset && zero_gap_offset == UINT32_MAX) {
      zero_gap_offset = covered;
    }
    covered = hash.ranges[i].offset + hash.ranges[i].size;
  }
  if (covered != hash.block_offset) {
    fail("canonical load map does not finish at the terminal block");
  }
  if (zero_gap_offset != UINT32_MAX) {
    std::vector<uint8_t> nonzero_gap = image;
    nonzero_gap[zero_gap_offset] = 1;
    expect_parse(nonzero_gap, false, "nonzero un-hashed load-map gap");
  }
  if (hash.block_hash_size < 8 ||
      hash.digest_offset != hash.block_offset + hash.block_hash_size + 4 ||
      hash.digest_offset + 32 > image.size()) {
    fail("canonical terminal hash layout changed");
  }

  const uint32_t root = find_root(image);
  if (get_word(image, root + 4) != 0x90210142 ||
      get_word(image, hash.block_offset + 4) != 0x90210142) {
    fail("canonical image definitions changed");
  }

  const uint32_t terminal = hash.block_offset;
  const uint32_t load_map = terminal + 16;
  const uint32_t terminal_last = hash.digest_offset + 32;

  std::vector<uint8_t> first_sector(image.begin(), image.begin() + 4096);
  std::vector<uint8_t> unpublished = image;
  std::fill(unpublished.begin(), unpublished.begin() + 4096, 0xff);
  expect_parse(unpublished, false, "erased unpublished first sector");
  ImageHash overlay_hash = {};
  if (!parse(unpublished, &overlay_hash, first_sector.data())) {
    fail("valid SRAM first-sector overlay was rejected");
  }
  if (overlay_hash.range_count != hash.range_count ||
      overlay_hash.block_offset != hash.block_offset ||
      overlay_hash.block_hash_size != hash.block_hash_size ||
      overlay_hash.digest_offset != hash.digest_offset) {
    fail("overlay parsing changed hash metadata");
  }
  for (unsigned i = 0; i < hash.range_count; i++) {
    if (overlay_hash.ranges[i].offset != hash.ranges[i].offset ||
        overlay_hash.ranges[i].size != hash.ranges[i].size) {
      fail("overlay parsing changed a hash range");
    }
  }
  std::vector<uint8_t> bad_overlay = first_sector;
  put_word(&bad_overlay, root + 4, 0x10210142);
  if (parse(unpublished, nullptr, bad_overlay.data())) {
    fail("overlay without first-block TBYB was accepted");
  }
  bad_overlay = first_sector;
  put_word(&bad_overlay, root + 20, 1);
  if (parse(unpublished, nullptr, bad_overlay.data())) {
    fail("overlay with unaligned terminal link was accepted");
  }

  expect_parse(changed_word(image, terminal + 4, 0x10210142), false,
               "terminal TBYB removed");
  expect_parse(changed_word(image, root + 4, 0x10210142), false,
               "first TBYB removed");
  expect_parse(changed_word(image, terminal + 12,
                            get_word(image, terminal + 12) + 0x00010000), false,
               "image definition version mismatch");
  expect_parse(changed_word(image, root + 8, 0x00000249), false,
               "unknown first-block item");
  expect_parse(changed_word(image, root + 16,
                            get_word(image, root + 16) + 0x100), false,
               "bad first LAST length");
  expect_parse(changed_word(image, root + 20, 1), false,
               "unaligned first link");
  expect_parse(changed_word(image, root + 20, uint32_t(image.size())), false,
               "out-of-range first link");
  expect_parse(changed_word(image, terminal_last,
                            get_word(image, terminal_last) + 0x100), false,
               "bad terminal LAST length");
  expect_parse(changed_word(image, terminal_last + 4, 0), false,
               "terminal link does not close loop");

  expect_parse(changed_word(image, load_map + 4, 0), false,
               "zero load-map reference");
  expect_parse(changed_word(image, load_map + 4,
                            get_word(image, load_map + 4) + 4), false,
               "load-map reference gap");
  expect_parse(changed_word(image, load_map + 12,
                            get_word(image, load_map + 12) - 4), false,
               "load-map coverage gap");
  expect_parse(changed_word(image, load_map + 8, 0x11000000), false,
               "invalid load-map runtime address");
  expect_parse(changed_word(image, load_map + 12, terminal + 4), false,
               "load-map range crosses metadata");
  std::vector<uint8_t> unaligned_ranges = image;
  put_word(&unaligned_ranges, load_map + 12,
           get_word(image, load_map + 12) - 1);
  put_word(&unaligned_ranges, load_map + 16,
           get_word(image, load_map + 16) - 1);
  put_word(&unaligned_ranges, load_map + 24,
           get_word(image, load_map + 24) + 1);
  expect_parse(unaligned_ranges, false,
               "unaligned but contiguous load-map ranges");

  std::vector<uint8_t> duplicate_marker = image;
  uint32_t duplicate_offset = root == 0 ? 4 : 0;
  put_word(&duplicate_marker, duplicate_offset, PICOBIN_BLOCK_MARKER_START);
  expect_parse(duplicate_marker, false, "multiple scan-window blocks");

  for (size_t length : {size_t(0), size_t(1), size_t(4095),
                        image.size() - 5, image.size() - 4,
                        image.size() - 1}) {
    std::vector<uint8_t> truncated(image.begin(), image.begin() + length);
    expect_parse(truncated, false, "truncated image");
  }
  std::vector<uint8_t> misaligned = image;
  misaligned.push_back(0);
  expect_parse(misaligned, false, "misaligned image size");
  std::vector<uint8_t> oversized(4 * 1024 * 1024 + 4);
  expect_parse(oversized, false, "oversized image");

  std::vector<uint8_t> body_corruption = image;
  body_corruption[root + 64] ^= 0x80;
  expect_parse(body_corruption, true, "body corruption left for digest check");
  std::vector<uint8_t> digest_corruption = image;
  digest_corruption[hash.digest_offset] ^= 0x80;
  expect_parse(digest_corruption, true, "digest corruption left for digest check");
}

uint32_t random_word(uint32_t* state) {
  uint32_t value = *state;
  value ^= value << 13;
  value ^= value >> 17;
  value ^= value << 5;
  *state = value;
  return value;
}

void run_boundary_fuzz(const std::vector<uint8_t>& image) {
  uint32_t state = 0x2350a5a5;
  std::vector<uint8_t> original_overlay(image.begin(), image.begin() + 4096);
  for (int iteration = 0; iteration < 25000; iteration++) {
    std::vector<uint8_t> candidate = image;
    unsigned mutations = 1 + random_word(&state) % 8;
    for (unsigned i = 0; i < mutations; i++) {
      size_t offset = random_word(&state) % candidate.size();
      candidate[offset] ^= uint8_t(1u << (random_word(&state) & 7));
    }
    if ((iteration & 7) == 0) {
      candidate.resize(random_word(&state) % (image.size() + 17));
    }
    ImageHash hash = {};
    parse_ota_image(candidate.data(), candidate.size(), &hash);
    if ((iteration & 1) == 0) {
      std::vector<uint8_t> overlay = original_overlay;
      unsigned overlay_mutations = 1 + random_word(&state) % 4;
      for (unsigned i = 0; i < overlay_mutations; i++) {
        size_t offset = random_word(&state) % overlay.size();
        overlay[offset] ^= uint8_t(1u << (random_word(&state) & 7));
      }
      parse_ota_image(candidate.data(), candidate.size(), &hash, overlay.data());
    }
  }
}

void print_inspection(const std::vector<uint8_t>& image) {
  ImageHash hash = {};
  if (!parse(image, &hash)) fail("inspection image was rejected");
  std::printf("%u %u %u", hash.block_offset, hash.block_hash_size,
              hash.digest_offset);
  for (unsigned i = 0; i < hash.range_count; i++) {
    std::printf(" %u %u", hash.ranges[i].offset, hash.ranges[i].size);
  }
  std::printf("\n");
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 3 && std::string(argv[1]) == "--inspect") {
    print_inspection(read_file(argv[2]));
    return 0;
  }
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s [--inspect] IMAGE.bin\n", argv[0]);
    return 2;
  }
  std::vector<uint8_t> image = read_file(argv[1]);
  run_regressions(image);
  run_boundary_fuzz(image);
  std::puts("ota_image_parser_test: PASS structure and boundary fuzz");
  return 0;
}
