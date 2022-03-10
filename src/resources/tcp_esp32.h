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

class LwIPSocket;

typedef LinkedFIFO<LwIPSocket> BacklogSocketList;

class LwIPSocket : public Resource, public BacklogSocketList::Element {
 public:
  TAG(LwIPSocket);
  enum Kind { kListening, kConnection };

  LwIPSocket(ResourceGroup* group, Kind kind)
    : Resource(group)
    , _kind(kind)
    , _tpcb(null)
    , _error(ERR_OK)
    , _needs_gc(false)
    , _send_pending(0)
    , _send_closed(false)
    , _read_buffer(null)
    , _read_offset(0)
    , _read_closed(false) {
  }

  ~LwIPSocket() {
    ASSERT(_tpcb == null);
  }

  void tear_down();

  static err_t on_accept(void* arg, tcp_pcb* tpcb, err_t err) {
    unvoid_cast<LwIPSocket*>(arg)->on_accept(tpcb, err);
    return ERR_OK;
  }
  void on_accept(tcp_pcb* tpcb, err_t err);

  static err_t on_connected(void* arg, tcp_pcb* tpcb, err_t err) {
    unvoid_cast<LwIPSocket*>(arg)->on_connected(err);
    return ERR_OK;
  }
  void on_connected(err_t err);

  static err_t on_read(void* arg, tcp_pcb* tpcb, pbuf* p, err_t err) {
    unvoid_cast<LwIPSocket*>(arg)->on_read(p, err);
    return ERR_OK;
  }
  void on_read(pbuf* p, err_t err);

  static err_t on_wrote(void* arg, tcp_pcb* tpcb, uint16_t length) {
    unvoid_cast<LwIPSocket*>(arg)->on_wrote(length);
    return ERR_OK;
  }
  void on_wrote(int length);

  static void on_error(void* arg, err_t err) {
    // Ignore if already deleted.
    if (arg == null) return;
    unvoid_cast<LwIPSocket*>(arg)->on_error(err);
  }
  void on_error(err_t err);

  void send_state();
  void socket_error(err_t err);

  Smi* as_smi() {
    return Smi::from(reinterpret_cast<uintptr_t>(this) >> 2);
  }

  static LwIPSocket* from_id(int id) {
    return reinterpret_cast<LwIPSocket*>(id << 2);
  }

  tcp_pcb* tpcb() { return _tpcb; }
  void set_tpcb(tcp_pcb* tpcb) { _tpcb = tpcb; }

  err_t error() { return _error; }
  bool needs_gc() { return _needs_gc; }
  void set_needs_gc() { _needs_gc = true; }
  void clear_needs_gc() { _needs_gc = false; }

  Kind kind() { return _kind; }

  int send_pending() { return _send_pending; }
  void set_send_pending(int pending) { _send_pending = pending; }
  bool send_closed() { return _send_closed; }
  void mark_send_closed() { _send_closed = true; }

  void set_read_buffer(pbuf* p) { _read_buffer = p; }
  pbuf* read_buffer() { return _read_buffer; }
  void set_read_offset(int offset) { _read_offset = offset; }
  int read_offset() { return _read_offset; }
  bool read_closed() { return _read_closed; }
  void mark_read_closed() { _read_closed = true; }

  void new_backlog_socket(tcp_pcb* tpcb);
  LwIPSocket* accept();

 private:
  Kind _kind;
  tcp_pcb* _tpcb;
  err_t _error;
  bool _needs_gc;

  int _send_pending;
  bool _send_closed;

  pbuf* _read_buffer;
  int _read_offset;
  bool _read_closed;

  // Sockets that are connected on a listening socket, but have not yet been
  // accepted by the application.
  BacklogSocketList _backlog;
};

} // namespace toit
