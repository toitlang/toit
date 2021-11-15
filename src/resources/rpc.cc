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

#ifndef IOT_DEVICE
#include "../event_sources/rpc_transport.h"
#include "../objects_inline.h"
#include "../process.h"
#endif
#include "../primitive.h"
#include "../top.h"


namespace toit {

class RpcResourceGroup : public ResourceGroup {
 public:
  TAG(RpcResourceGroup);
  RpcResourceGroup(Process* process, EventSource* event_source)
      : ResourceGroup(process, event_source) {}

  uint32_t on_event(Resource* resource, word data, uint32_t state) {
    return state | data;
  }
};

MODULE_IMPLEMENTATION(rpc, MODULE_RPC)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  RpcResourceGroup* resource_group = _new RpcResourceGroup(process, InterProcessMessageEventSource::instance());
  if (resource_group == null) MALLOC_FAILED;

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(create_channel) {
  ARGS(RpcResourceGroup, resource_group, Blob, uuid);

  if (uuid.length() != UUID_SIZE) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  Channel* channel = Channel::create(uuid.address());
  if (channel == null) MALLOC_FAILED;

  Peer* peer = _new Peer(resource_group);
  if (peer == null) {
    delete channel;
    MALLOC_FAILED;
  }
  InterProcessMessageEventSource* event_source = InterProcessMessageEventSource::instance();
  event_source->attach(peer, channel);
  event_source->add_pending_channel(channel);
  resource_group->register_resource(peer);
  proxy->set_external_address(peer);
  return proxy;
}

PRIMITIVE(open_channel) {
  ARGS(RpcResourceGroup, resource_group, Blob, uuid);

  if (uuid.length() != UUID_SIZE) INVALID_ARGUMENT;

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  Peer* peer = _new Peer(resource_group);
  if (peer == null) MALLOC_FAILED;

  Channel* channel = InterProcessMessageEventSource::instance()->take_pending_channel(uuid.address());
  if (channel == null) return process->program()->null_object();

  InterProcessMessageEventSource::instance()->attach(peer, channel);
  resource_group->register_resource(peer);
  proxy->set_external_address(peer);
  return proxy;
}

PRIMITIVE(send_status) {
  ARGS(Peer, peer, int32, status);
  InterProcessMessageEventSource::instance()->send_status(peer, status);
  return process->program()->null_object();
}

PRIMITIVE(has_frame) {
  ARGS(Peer, peer);
  return BOOL(InterProcessMessageEventSource::instance()->has_frame(peer));
}

PRIMITIVE(get_stream_id) {
  ARGS(Peer, peer);
  if (!InterProcessMessageEventSource::instance()->has_frame(peer)) OUT_OF_RANGE;
  int stream_id = InterProcessMessageEventSource::instance()->read_stream_id(peer);
  return Primitive::integer(stream_id, process);
}

PRIMITIVE(get_bits) {
  ARGS(Peer, peer);
  if (!InterProcessMessageEventSource::instance()->has_frame(peer)) OUT_OF_RANGE;
  int bits = InterProcessMessageEventSource::instance()->read_bits(peer);
  return Primitive::integer(bits, process);
}

PRIMITIVE(take_bytes) {
  ARGS(Peer, peer);
  if (!InterProcessMessageEventSource::instance()->has_frame(peer)) return process->program()->null_object();

  int length = InterProcessMessageEventSource::instance()->read_length(peer);
  uint8* data = InterProcessMessageEventSource::instance()->read_bytes(peer);

  ASSERT(data != null);

  ByteArray* proxy = process->object_heap()->allocate_proxy(length, data, true);
  if (proxy == null) ALLOCATION_FAILED;

  // Transfer the allocation to a ByteArray. The receiving process now owns
  // the allocation.
  process->register_external_allocation(length);
  InterProcessMessageEventSource::instance()->clear_bytes(peer);
  return proxy;
}

PRIMITIVE(skip) {
  ARGS(Peer, peer);
  InterProcessMessageEventSource::instance()->skip_frame(peer);
  return process->program()->null_object();
}

PRIMITIVE(send) {
  ARGS(Peer, peer, int, stream_id, int32, bits, Object, array);

  bool take_external_data = array->is_byte_array() &&
      ByteArray::cast(array)->has_external_address();

  int length;
  uint8* data = null;
  if (take_external_data) {
    ByteArray::Bytes bytes(ByteArray::cast(array));
    length = bytes.length();
    data = bytes.address();
  } else {
    const uint8* array_address;
    if (!array->byte_content(process->program(), &array_address, &length, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
    data = unvoid_cast<uint8_t*>(malloc(length));
    if (data == null) MALLOC_FAILED;
    memcpy(data, array_address, length);
  }
  if (!InterProcessMessageEventSource::instance()->send(peer, stream_id, bits, length, data)) {
    if (!take_external_data) free(data);
    return process->program()->false_object();
  }
  // The data allocation is now owned by the internal Stream until the receiver
  // takes ownership with the take_bytes primitive.

  if (take_external_data) ByteArray::cast(array)->neuter(process);

  return process->program()->true_object();
}

PRIMITIVE(close) {
  ARGS(ResourceGroup, resource_group, Peer, peer);
  resource_group->unregister_resource(peer);

  peer_proxy->clear_external_address();

  return process->program()->null_object();
}

}
