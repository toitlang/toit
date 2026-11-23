// Copyright (C) 2026 Toit contributors.

#include "prelude.h"

namespace toit { class MessageEncoder; }
static void visit_tag(toit::MessageEncoder*, uint8);
static void visit_cardinal(toit::MessageEncoder*, uword);
static void visit_pointer(toit::MessageEncoder*, void*);
static void* allocate_copy(size_t);
static void copy_payload(void*, const void*, size_t);
#define protected public
#define private public
#include "ipc_byte_array_visit.inc"
#undef private
#undef protected

using namespace toit;

static ByteArray* current;
// Each identity represents a distinct payload allocation. Its byte models
// the content at the arbitrary logical offset witness.
static uint8 source_byte, copy_byte;
static uint8* envelope;
static word length, measured, witness;
static unsigned digits, fields;
static bool repeat, inlined;
static bool allocation_ok;
static unsigned requests, copies, views;

// These three operations are checked together with the native readers by
// ipc-array-fields. Here we check their arguments and order on every visit.
static void visit_tag(MessageEncoder* encoder, uint8 tag) {
  CXXV_ASSERT(fields == 0 && encoder->size() == 0 && tag == (inlined ? TAG_BYTE_ARRAY_INLINE : TAG_BYTE_ARRAY),
              "start with the specified byte-array tag");
  ++fields;
  ++encoder->cursor_;
}

static void visit_cardinal(MessageEncoder* encoder, uword value) {
  CXXV_ASSERT(fields == 1 && encoder->size() == 1 && value == static_cast<uword>(length),
              "encode the exact original length after the tag");
  ++fields;
  encoder->cursor_ += digits;
}

static void visit_pointer(MessageEncoder* encoder, void* pointer) {
  void* expected = repeat ? (encoder->encoding_for_size() ? nullptr : &copy_byte) : &source_byte;
  CXXV_ASSERT(fields == 2 && encoder->size() == static_cast<word>(1 + digits) && !inlined && pointer == expected,
              "follow the length with the original, fresh, or sizing-only pointer");
  ++fields;
  encoder->cursor_ += WORD_SIZE;
}

bool Object::byte_content(Program*, const uint8** data, word* size, BlobKind kind) const {
  CXXV_ASSERT(this == current && kind == STRINGS_OR_BYTE_ARRAYS, "read byte content from the original repeated reference");
  ++views;
  *data = &source_byte;
  *size = length;
  return true;
}

static void* allocate_copy(size_t size) {
  CXXV_ASSERT(size == static_cast<size_t>(length) && length > MESSAGING_ENCODING_MAX_INLINED_SIZE,
              "allocate exactly the large duplicate's payload");
  ++requests;
  return allocation_ok ? &copy_byte : nullptr;
}

// The memcpy contract at the two payload copy sites.
static void copy_payload(void* destination, const void* original, size_t size) {
  CXXV_ASSERT(original == &source_byte && size == static_cast<size_t>(length), "copy exactly the original payload");
  if (length <= MESSAGING_ENCODING_MAX_INLINED_SIZE) {
    CXXV_ASSERT(measured >= length && destination == envelope + (measured - length), "inline bytes end at the measured boundary");
    if (length > 0) static_cast<uint8*>(destination)[witness] = source_byte;
  } else {
    CXXV_ASSERT(allocation_ok && destination == &copy_byte, "out-of-line bytes go into the fresh allocation");
    copy_byte = source_byte;
  }
  ++copies;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword words[ByteArray::EXTERNAL_SIZE / WORD_SIZE] = {2 * BYTE_ARRAY_TAG};
  current = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  length = nondet_word();
  CXXV_ASSUME(length >= 0 && length <= MESSAGING_ENCODING_MAX_SIZE);
  word capacity = length > 0 ? length : 1;
  witness = nondet_word();
  CXXV_ASSUME(witness >= 0 && witness < capacity);
  uint8 expected_byte = nondet_uchar();
  source_byte = expected_byte;
  current->_initialize_external_memory(length, &source_byte, false);
  current->set_has_active_finalizer();

  unsigned owners = nondet_uint(), reserved = nondet_uint();
  CXXV_ASSUME(owners <= reserved && reserved <= MESSAGING_ENCODING_MAX_EXTERNALS);
  int index = nondet_int();
  CXXV_ASSUME(index >= -1 && index < static_cast<int>(owners));
  repeat = index >= 0;
  ByteArray* prior[MESSAGING_ENCODING_MAX_EXTERNALS];
  uword identities[MESSAGING_ENCODING_MAX_EXTERNALS];
  for (unsigned i = 0; i < MESSAGING_ENCODING_MAX_EXTERNALS; ++i) {
    prior[i] = static_cast<int>(i) == index ? current :
        static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(&identities[i])));
  }
  word charged = nondet_word();
  CXXV_ASSUME(charged >= 0 && charged <= MESSAGING_ENCODING_MAX_SIZE);
  inlined = repeat && length <= MESSAGING_ENCODING_MAX_INLINED_SIZE;
  bool room = length <= MESSAGING_ENCODING_MAX_SIZE - charged;
  bool table_room = inlined || reserved < MESSAGING_ENCODING_MAX_EXTERNALS;
  // Check each pass against the same wire layout. The writing allocation
  // has exactly the size that the sizing pass must return on success.
  digits = 1;
  for (uword remaining = length; remaining >= 128; remaining >>= 7) ++digits;
  word payload_offset = 1 + digits;
  measured = payload_offset + (inlined ? length : WORD_SIZE);
  uint8 storage[measured];
  envelope = storage;
  bool sizing = nondet_bool();
  allocation_ok = nondet_bool();
  MessageEncoder encoder(nullptr, sizing ? nullptr : storage, MESSAGE_FORMAT_IPC, false);
  encoder.external_bytes_ = charged;
  encoder.transferred_count_ = owners;
  encoder.externals_count_ = reserved;
  unsigned prior_copies = sizing ? 0 : reserved - owners;
  uint8 previous_copies[MESSAGING_ENCODING_MAX_EXTERNALS];
  encoder.copied_count_ = prior_copies;
  for (unsigned i = 0; i < MESSAGING_ENCODING_MAX_EXTERNALS; ++i) {
    encoder.transferred_[i] = prior[i];
    encoder.copied_[i] = &previous_copies[i];
  }
  bool encoded = encoder.encode_byte_array(current);
  bool admitted = room && table_room;
  bool allocate = admitted && !sizing && repeat && !inlined;
  CXXV_ASSERT(encoded == (admitted && (!allocate || allocation_ok)) &&
              views == static_cast<unsigned>(repeat) && requests == static_cast<unsigned>(allocate),
              "classify each reference and allocate only for an admitted out-of-line duplicate");
  // Transfers reserve before checking the length. Copies check length first.
  bool reserved_here = !inlined && table_room && (!repeat || room);
  CXXV_ASSERT(encoder.externals_count_ == reserved + reserved_here &&
              encoder.too_many_externals_ == (!table_room && (!repeat || room)) &&
              encoder.too_large() == (!room && (repeat || table_room)) &&
              encoder.malloc_failed() == (allocate && !allocation_ok), "report the first failure with the exact reservation count");
  CXXV_ASSERT(encoder.size() == (encoded ? measured : 0) &&
              encoder.external_bytes_ == charged + (admitted && !inlined ? length : 0),
              "both passes match the specified wire extent and out-of-line charge");
  CXXV_ASSERT(current->as_external() == &source_byte && current->_external_length() == length &&
              current->has_active_finalizer() && encoder.transferred_count_ == owners + (encoded && !repeat) &&
              encoder.copied_count_ == prior_copies + (allocate && allocation_ok) &&
              copies == static_cast<unsigned>(encoded && repeat && !sizing), "retain the sender's owner until publication");
  unsigned slot = nondet_uint();
  CXXV_ASSUME(slot < MESSAGING_ENCODING_MAX_EXTERNALS);
  if (slot < owners) CXXV_ASSERT(encoder.transferred_[slot] == prior[slot], "preserve every prior transfer");
  if (slot < prior_copies) CXXV_ASSERT(encoder.copied_[slot] == &previous_copies[slot], "preserve every prior copy");
  if (encoded && !repeat) CXXV_ASSERT(encoder.transferred_[owners] == current, "append exactly the new transfer");
  CXXV_ASSERT(fields == (encoded ? (inlined ? 2u : 3u) : 0u), "emit every field on success and none on failure");
  if (encoded && !sizing && repeat) {
    if (inlined) {
      if (length > 0) CXXV_ASSERT(storage[payload_offset + witness] == expected_byte, "preserve each inline source byte");
    } else {
      CXXV_ASSERT(encoder.copied_[prior_copies] == &copy_byte && copy_byte == expected_byte,
                  "record the fresh copy with its original contents");
    }
  }
  // Native teardown for populated owner tables has its own proof.
  encoder.copied_count_ = 0;
}
