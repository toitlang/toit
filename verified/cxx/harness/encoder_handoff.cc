// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
static void release_block(void*);
namespace toit {
class ByteArray;
static void observe_finalizer_clear(ByteArray*);
}
#define private public
#define protected public
#define free release_block
#include "encoder_tables.inc"
#undef free
#undef protected
#undef private

using namespace toit;
extern Process sender;
static const unsigned limit = MESSAGING_ENCODING_MAX_EXTERNALS;
static uint8 buffer[1], copies[limit], external[limit];
static unsigned copy_count, transfers, releases, buffer_releases, refunds, cleared;
static ByteArray identities[limit];

static void release_block(void* block) {
  if (block == nullptr) return;
  if (block == buffer) {
    CXXV_ASSERT(buffer_releases == 0, "release the encoded buffer at most once");
    ++buffer_releases;
  } else {
    CXXV_ASSERT(releases < copy_count && block == &copies[releases], "free each owned copy exactly once in table order");
    ++releases;
  }
}

// The byte-array-neuter gate proves the storage transfer, refund and
// preservation of the header. Here the observer checks the call sequence.
uint8* ByteArray::neuter(Process* process) {
  CXXV_ASSERT(process == &sender && refunds == cleared && refunds < transfers && this == &identities[refunds],
              "detach each registered array exactly once from its original process");
  ++refunds;
  return &external[refunds - 1];
}

void toit::observe_finalizer_clear(ByteArray* array) {
  CXXV_ASSERT(cleared < transfers && refunds == cleared + 1 && array == &identities[cleared],
              "clear the finalizer of the array just detached");
  ++cleared;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  transfers = nondet_uint();
  copy_count = nondet_uint();
  CXXV_ASSUME(transfers <= limit && copy_count <= limit - transfers);
  bool publish = nondet_bool();
  unsigned witness = nondet_uint();
  CXXV_ASSUME(witness < limit);
  SystemMessage* message = nullptr;
  int type = nondet_int(), gid = nondet_int(), pid = nondet_int();
  {
    auto* owner = new MessageEncoder(&sender, buffer);
    CXXV_ASSUME(owner != nullptr);
    MessageEncoder& encoder = *owner;
    CXXV_ASSERT(encoder.buffer_ == buffer && encoder.take_ownership_of_buffer_, "IPC encoder owns its supplied buffer");
    encoder.transferred_count_ = transfers;
    encoder.copied_count_ = copy_count;
    for (unsigned i = 0; i < limit; ++i) {
      if (i < transfers) encoder.transferred_[i] = &identities[i];
      if (i < copy_count) encoder.copied_[i] = &copies[i];
    }
    if (publish) {
      message = new SystemMessage(type, gid, pid, &encoder);
      CXXV_ASSUME(message != nullptr);
      CXXV_ASSERT(message->data() == buffer && message->type() == type && message->gid() == gid && message->pid() == pid,
                  "publish the original encoder buffer and envelope metadata");
      CXXV_ASSERT(encoder.buffer_ == nullptr && (witness >= copy_count || encoder.copied_[witness] == nullptr),
                  "disarm buffer and copied-block ownership before the encoder leaves scope");
    }
    owner->MessageEncoder::~MessageEncoder();
    ::operator delete(owner);
  }
  CXXV_ASSERT(cleared == refunds && refunds == (publish ? transfers : 0) && releases == (publish ? 0 : copy_count) &&
              buffer_releases == (publish ? 0u : 1u), "abort frees owned storage, while publication leaves it with the message");
  if (publish) {
    message->free_data_but_keep_externals();
    CXXV_ASSERT(buffer_releases == 1 && releases == 0 && message->data() == nullptr,
                "receiver can release the envelope while retaining its external blocks");
  }
}
