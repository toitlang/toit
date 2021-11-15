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

#include "../resource.h"
#include "../os.h"
#include "../linked.h"

namespace toit {

enum notify_status : int32 {
  STATUS_SEND = 1,
  STATUS_OPEN = 2,
  STATUS_WRITE = 4,
  STATUS_CLOSED = 8,
};

class Channel;
typedef LinkedList<Channel> ChannelList;
class Frame {
 public:
  Frame() { }

  Frame(int stream_id, int bits, int length, uint8* data)
    : _stream_id(stream_id)
    , _bits(bits)
    , _length(length)
    , _data(data) { }


  int stream_id() { return _stream_id; }
  int bits() { return _bits; }
  int length() { return _length; }
  uint8* data() { return _data; }
  void clear_data() { _data = null; }

 private:
  int _stream_id;
  int _bits;
  int _length;
  uint8* _data;

  friend class Stream;
};

/*
  Stream of Frames.
*/
class Stream {
 public:
  ~Stream() {
    for (int i = 0; i < _length; i++) {
      int index = (_front_index + i) % CHANNEL_SIZE;
      free(_buffer[index].data());
    }
  }

  bool insert(const Frame& frame);

  Frame* get_frame();

  void skip();

  int bytes_in_transit() { return _bytes_owned; }
  bool is_full() { return _length == CHANNEL_SIZE; }

 private:
  static int const CHANNEL_SIZE = 8;
  int _front_index = 0;
  int _length = 0;
  int _bytes_owned = 0;
  Frame _buffer[CHANNEL_SIZE];
};

class Peer : public Resource {
 public:
  TAG(Peer);
  // Holds references for the streams and the channel. Knows which stream to send and receive on.
  Peer(ResourceGroup* resource_group)
    : Resource(resource_group) { }
  ~Peer();

  int id() { return _id; }

 private:
  void attach(Channel* channel, int id) {
    _id = id;
    _channel = channel;
  }

  Peer* other_peer();

  Channel* _channel = null;
  int _id;

  friend class Channel;
  friend class InterProcessMessageEventSource;
};

/*
  Bidirectional stream of frames.
*/
class Channel : public ChannelList::Element {
 // TODO(Lau): Add status of channel.
 public:
  TAG(Channel);
  Channel() { }

  static Channel* create(const uint8* uuid);

  ~Channel() {
    ASSERT(_peers[0] == null && _peers[1] == null);
  }

 private:
  void attach(Peer* peer);
  bool is_open() {
    return _peers[0] != null && _peers[1] != null;
  }
  bool is_deletable() {
    return _peers[0] == null && _peers[1] == null;
  }

  bool send(Peer* sender, const Frame& frame);

  Frame* get_frame(int peer_id) {
    return _streams[peer_id].get_frame();
  }

  void skip(int peer_id) {
    _streams[peer_id].skip();
  }

  bool is_full(int peer_id) {
    return _streams[peer_id].is_full() || _streams[peer_id].bytes_in_transit() > BYTES_IN_TRANSIT_THRESHOLD;
  }

  static const int OK_STATUS = 1;
  static const int FAILED_STATUS = 2;

  static const int BYTES_IN_TRANSIT_THRESHOLD = 4096;

  int _next_id = 0;
  Peer* _peers[2] = { null, null };
  Stream _streams[2];
  // TODO(Lau): We don't need the ID once the channel is opened in both ends. Make this a pointer and free the space and null it when it has been taken.
  uint8 _uuid[UUID_SIZE];

  friend class Peer;
  friend class InterProcessMessageEventSource;
};


class InterProcessMessageEventSource : public EventSource {
 public:
  static InterProcessMessageEventSource* instance() { return _instance; }

  InterProcessMessageEventSource();
  ~InterProcessMessageEventSource();

  void on_register_resource(Locker& locker, Resource* r) { }
  void on_unregister_resource(Locker& locker, Resource* r) {
    Peer* peer = static_cast<Peer*>(r);
    Channel* channel = peer->_channel;
    take_pending_channel(channel->_uuid);

    Peer* other_peer = peer->other_peer();
    if (other_peer) dispatch(locker, other_peer, STATUS_CLOSED);
  }

  bool send(Peer* sender, int stream_id, int32 header, int length, uint8* bytes);
  void send_status(Peer* sender, int32 status);

  bool has_frame(Peer* receiver);
  int read_stream_id(Peer* receiver);
  int read_bits(Peer* receiver);
  int read_length(Peer* receiver);
  uint8* read_bytes(Peer* receiver);
  void clear_bytes(Peer* receiver);
  void skip_frame(Peer* receiver);

  Channel* take_pending_channel(const uint8* uuid);
  void add_pending_channel(Channel* half_open);

  void attach(Peer* peer, Channel* channel);

 private:
  Frame* get_frame(Locker& locker, Peer* receiver) { return receiver->_channel->get_frame(receiver->id()); }
  void send_status(Locker& locker, Peer* sender, int32 status);
  static InterProcessMessageEventSource* _instance;

  ChannelList _pending_channels;
};

} // namespace toit
