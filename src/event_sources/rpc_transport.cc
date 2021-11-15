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

#include "rpc_transport.h"

namespace toit {

InterProcessMessageEventSource* InterProcessMessageEventSource::_instance = null;

InterProcessMessageEventSource::InterProcessMessageEventSource() :
  EventSource("InterProcessMessaging") {

  ASSERT(_instance == null);
  _instance = this;
}

InterProcessMessageEventSource::~InterProcessMessageEventSource() {
  _instance = null;
}

bool InterProcessMessageEventSource::send(Peer* sender, int stream_id, int32 bits, int length, uint8* bytes) {
  Locker locker(mutex());
  Frame frame(stream_id, bits, length, bytes);
  if (!sender->_channel->send(sender, frame)) return false;
  send_status(locker, sender, STATUS_SEND);
  return true;
}

void InterProcessMessageEventSource::send_status(Peer* sender, int32 status) {
  Locker locker(mutex());
  send_status(locker, sender, status);
}

void InterProcessMessageEventSource::send_status(Locker& locker, Peer* sender, int32 status) {
  Peer* receiver = sender->other_peer();
  if (receiver != null) dispatch(locker, receiver, status);
}

bool InterProcessMessageEventSource::has_frame(Peer* receiver) {
  Locker locker(mutex());
  return get_frame(locker, receiver) != null;
}

int32 InterProcessMessageEventSource::read_stream_id(Peer* receiver) {
  Locker locker(mutex());
  Frame* frame = get_frame(locker, receiver);
  ASSERT(frame != null);
  return frame->stream_id();
}

int InterProcessMessageEventSource::read_bits(Peer* receiver) {
  Locker locker(mutex());
  Frame* frame = get_frame(locker, receiver);
  ASSERT(frame != null);
  return frame->bits();
}

int InterProcessMessageEventSource::read_length(Peer* receiver) {
  Locker locker(mutex());
  Frame* frame = get_frame(locker, receiver);
  ASSERT(frame != null);
  return frame->length();
}

uint8* InterProcessMessageEventSource::read_bytes(Peer* receiver) {
  Locker locker(mutex());
  Frame* frame = get_frame(locker, receiver);
  ASSERT(frame != null);
  return frame->data();
}

void InterProcessMessageEventSource::clear_bytes(Peer* receiver) {
  Locker locker(mutex());
  Frame* frame = get_frame(locker, receiver);
  ASSERT(frame != null);
  frame->clear_data();
}

void InterProcessMessageEventSource::skip_frame(Peer* receiver) {
  Locker locker(mutex());
  Frame* frame = get_frame(locker, receiver);
  if (frame == null) return;
  int receiver_id = receiver->id();
  bool was_full = receiver->_channel->is_full(receiver_id);
  receiver->_channel->skip(receiver_id);
  bool is_full = receiver->_channel->is_full(receiver_id);
  if (receiver->other_peer() != null && was_full && !is_full) dispatch(locker, receiver->other_peer(), STATUS_WRITE);
}

Channel* InterProcessMessageEventSource::take_pending_channel(const uint8* uuid) {
  return _pending_channels.remove_where([&uuid](Channel* channel) {
    return memcmp(channel->_uuid, uuid, UUID_SIZE) == 0;
  });
}

void InterProcessMessageEventSource::add_pending_channel(Channel* half_open) {
  _pending_channels.prepend(half_open);
}

void InterProcessMessageEventSource::attach(Peer* peer, Channel* channel) {
  Locker locker(mutex());
  channel->attach(peer);
  if (channel->is_open()) {
    dispatch(locker, channel->_peers[0], STATUS_WRITE);
    dispatch(locker, channel->_peers[1], STATUS_WRITE);
  }
}

Channel* Channel::create(const uint8* uuid) {
  Channel* channel = _new Channel();
  if (channel == null) return null;
  memcpy(channel->_uuid, uuid, UUID_SIZE);
  return channel;
}

bool Channel::send(Peer* sender, const Frame& frame) {
  if (!is_open()) return false;
  int receiver_id = sender->_id ^ 1;
  if (is_full(receiver_id)) return false;
  return _streams[receiver_id].insert(frame);
}

void Channel::attach(Peer* peer) {
  ASSERT(0 <= _next_id && _next_id < 2);

  int id = _next_id++;
  peer->attach(this, id);
  _peers[id] = peer;
}

bool Stream::insert(const Frame& frame) {
  if (is_full()) return false;
  ASSERT(_length < CHANNEL_SIZE);

  int next_free = (_front_index + _length) % CHANNEL_SIZE;
  _buffer[next_free] = frame;
  _length++;
  _bytes_owned += frame._length;
  ASSERT(_length <= CHANNEL_SIZE);
  return true;
}

Frame* Stream::get_frame() {
  if (_length == 0) return null;
  return &_buffer[_front_index];
}

void Stream::skip() {
  ASSERT(_length > 0);
  if (_length == 0) return;

  _bytes_owned -= _buffer[_front_index]._length;
  _front_index = (_front_index + 1) % CHANNEL_SIZE;
  _length--;
}

Peer* Peer::other_peer() {
  if (!_channel->is_open()) return null;
  int other_id = _id ^ 1;
  return _channel->_peers[other_id];
}

Peer::~Peer() {
  if (_channel != null) {
    _channel->_peers[_id] = null;
    if (_channel->is_deletable()) delete _channel;
  }
}

}
