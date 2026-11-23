// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
static void release_block(void*);
#define protected public
#define private public
#define free release_block
#include "ipc_external_messaging.inc"
#undef free
#undef private
#undef protected
namespace toit {
#include "byte_array_neuter.inc"
}

using namespace toit;
extern Process sender;
static uint8* buffer;
static uint8 payload;
static unsigned buffer_frees, payload_frees, refunds;
static word length;

bool Object::byte_content(Program*, const uint8**, word*, BlobKind) const {
  CXXV_ASSERT(false, "a first occurrence of an owned external array takes the transfer branch");
  return false;
}

void toit::fail(const char*, ...) {
  CXXV_ASSERT(false, "the encoded byte array always has a recognized IPC tag");
  abort();
}

static void release_block(void* block) {
  if (block == nullptr) return;
  if (block == &payload) {
    CXXV_ASSERT(buffer_frees == 0 && payload_frees == 0, "dispose the original external pointer exactly once before the envelope");
    ++payload_frees;
  } else {
    CXXV_ASSERT(block == buffer && buffer_frees == 0, "dispose only the allocated envelope");
    ++buffer_frees;
  }
}

void ObjectHeap::unregister_external_allocation(word size) {
  CXXV_ASSERT(this == sender.object_heap() && size == length && refunds == 0,
              "refund the full original length exactly once on publication");
  ++refunds;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  uword words[ByteArray::EXTERNAL_SIZE / WORD_SIZE] = {2 * BYTE_ARRAY_TAG};
  auto* array = static_cast<ByteArray*>(HeapObject::from_address(reinterpret_cast<uword>(words)));
  length = nondet_word();
  CXXV_ASSUME(0 <= length && length <= MESSAGING_ENCODING_MAX_SIZE);
  array->_initialize_external_memory(length, &payload, false);
  array->set_has_active_finalizer();
  word measured;
  {
    MessageEncoder sizing(&sender, nullptr);
    bool encoded = sizing.encode_byte_array(array);
    measured = sizing.size();
    CXXV_ASSERT(encoded && measured >= WORD_SIZE + 2 && measured <= WORD_SIZE + 6 &&
                sizing.total_size() == length + measured, "measure the tag, cardinal and pointer plus external storage");
    bool oversized = sizing.is_too_large();
    CXXV_ASSERT(oversized == (length + measured > MESSAGING_ENCODING_MAX_SIZE), "include the envelope bytes in the IPC size limit");
    if (oversized) {
      CXXV_ASSERT(array->as_external() == &payload && array->has_active_finalizer(),
                  "reject an oversized envelope before transfer");
      return 0;
    }
  }
  // The allocation contract on the successful path supplies exactly this many bytes.
  uint8 storage[measured];
  buffer = storage;
  bool publish = nondet_bool();
  {
    auto* owner = new MessageEncoder(&sender, buffer);
    CXXV_ASSUME(owner != nullptr);
    MessageEncoder& writer = *owner;
    bool encoded = writer.encode_byte_array(array);
    CXXV_ASSERT(encoded && !writer.is_too_large() && writer.size() == measured &&
                writer.total_size() == measured + length, "write exactly the measured envelope");
    MessageDecoder reader(buffer);
    int tag = reader.read_uint8();
    uword decoded_length = reader.read_cardinal();
    uint8* address = reader.read_pointer();
    CXXV_ASSERT(tag == TAG_BYTE_ARRAY && decoded_length == static_cast<uword>(length) &&
                address == &payload && reader.success() && reader.cursor_ == measured,
                "read the original tag, external length and pointer and finish at the end of the allocated envelope");
    // Materialize the proved discriminator so symbolic execution can prune
    // the recursive array/map cases in the native destructor.
    CXXV_ASSERT(buffer[0] == TAG_BYTE_ARRAY, "the encoded discriminator is the external byte-array tag");
    buffer[0] = TAG_BYTE_ARRAY;
    if (publish) {
      auto* message = new SystemMessage(SYSTEM_RPC_REPLY, 1, 2, &writer);
      CXXV_ASSUME(message != nullptr);
      CXXV_ASSERT(message->data() == buffer && array->as_external() == nullptr && array->_external_length() == 0 &&
                  !array->has_active_finalizer(), "move the external block from the sender into the message");
      // Use the concrete destructor at the virtual dispatch boundary.
      message->SystemMessage::~SystemMessage();
      ::operator delete(message);
    }
    owner->MessageEncoder::~MessageEncoder();
    ::operator delete(owner);
  }
  CXXV_ASSERT(buffer_frees == 1 && payload_frees == publish && refunds == publish,
              "a dropped published message releases both allocations and an aborted write releases only its envelope");
  if (!publish) {
    CXXV_ASSERT(array->as_external() == &payload && array->_external_length() == length && array->has_active_finalizer(),
                "preserve the sender's ownership on abort");
  }
}
