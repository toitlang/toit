// Copyright (C) 2018 Toitware ApS.
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

#include "lwip/tcp.h"
#include "lwip/tcpip.h"

#include "../os.h"
#include "../objects.h"
#include "../resource.h"

namespace toit {

class LwipSocket;

typedef LinkedFifo<LwipSocket> BacklogSocketList;

class LwipSocket : public Resource, public BacklogSocketList::Element {
 public:
  TAG(LwipSocket);
  enum Kind { kListening, kConnection };

  LwipSocket(ResourceGroup* group, Kind kind)
    : Resource(group)
    , kind_(kind)
    , tpcb_(null)
    , error_(ERR_OK)
    , send_pending_(0)
    , send_closed_(false)
    , read_buffer_(null)
    , read_offset_(0)
    , read_closed_(false) {}

  ~LwipSocket() {
    ASSERT(tpcb_ == null);
  }

  void tear_down();

  static err_t on_accept(void* arg, tcp_pcb* tpcb, err_t err) {
    int result = unvoid_cast<LwipSocket*>(arg)->on_accept(tpcb, err);
    return result;
  }
  int on_accept(tcp_pcb* tpcb, err_t err);

  static err_t on_connected(void* arg, tcp_pcb* tpcb, err_t err) {
    int result = unvoid_cast<LwipSocket*>(arg)->on_connected(err);
    return result;
  }
  int on_connected(err_t err);

  static err_t on_read(void* arg, tcp_pcb* tpcb, pbuf* p, err_t err) {
    unvoid_cast<LwipSocket*>(arg)->on_read(p, err);
    return ERR_OK;
  }
  void on_read(pbuf* p, err_t err);

  static err_t on_wrote(void* arg, tcp_pcb* tpcb, uint16_t length) {
    unvoid_cast<LwipSocket*>(arg)->on_wrote(length);
    return ERR_OK;
  }
  void on_wrote(int length);

  static void on_error(void* arg, err_t err) {
    // Ignore if already deleted.
    if (arg == null) return;
    unvoid_cast<LwipSocket*>(arg)->on_error(err);
  }
  void on_error(err_t err);

  void send_state();
  void socket_error(err_t err);

  tcp_pcb* tpcb() { return tpcb_; }
  void set_tpcb(tcp_pcb* tpcb) { tpcb_ = tpcb; }

  err_t error() { return error_; }

  Kind kind() { return kind_; }

  int send_pending() { return send_pending_; }
  void set_send_pending(int pending) { send_pending_ = pending; }
  bool send_closed() { return send_closed_; }
  void mark_send_closed() { send_closed_ = true; }

  void set_read_buffer(pbuf* p, int offset) {
    read_buffer_ = p;
    read_offset_ = offset;
  }
  pbuf* get_read_buffer(int* offset_return) {
    *offset_return = read_offset_;
    return read_buffer_;
  }
  bool read_closed() { return read_closed_; }
  void mark_read_closed() { read_closed_ = true; }

  int new_backlog_socket(tcp_pcb* tpcb);
  LwipSocket* accept();

 private:
  Kind kind_;
  tcp_pcb* tpcb_;
  err_t error_;

  int send_pending_;
  bool send_closed_;

  pbuf* read_buffer_;
  int read_offset_;
  bool read_closed_;

  // Sockets that are connected on a listening socket, but have not yet been
  // accepted by the application.
  BacklogSocketList backlog_;
};

} // namespace toit
