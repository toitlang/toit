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

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/debug.h>
#include <mbedtls/entropy.h>
#include <mbedtls/net.h>
#include <mbedtls/ssl_cookie.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crl.h>

#include "../heap.h"
#include "../resource.h"

#include "../event_sources/tls.h"

#if defined(TOIT_FREERTOS)
#include "tcp_esp32.h"
#endif

namespace toit {

class MbedTLSResourceGroup;
class MbedTLSSocket;
class X509Certificate;

Object* tls_error(MbedTLSResourceGroup* group, Process* process, int err);
bool ensure_handshake_memory();

enum TLS_STATE {
  TLS_DONE = 1 << 0,
  TLS_WANT_READ = 1 << 1,
  TLS_WANT_WRITE = 1 << 2,
  TLS_SENT_HELLO_VERIFY = 1 << 3,
};

// Common base for TLS (stream based) and in the future perhaps DTLS (datagram based) sockets.
class BaseMbedTLSSocket : public TLSSocket {
 public:
  BaseMbedTLSSocket(MbedTLSResourceGroup* group);
  ~BaseMbedTLSSocket();

  mbedtls_ssl_context ssl;

  virtual bool init(const char* transport_id) = 0;
  void apply_certs();
  int add_certificate(X509Certificate* cert, const uint8_t* private_key, size_t private_key_length, const uint8_t* password, int password_length);
  int add_root_certificate(X509Certificate* cert);
  void uninit_certs();
  word handshake() override;

 protected:
  mbedtls_ssl_config _conf;

 private:
  mbedtls_x509_crt* _root_certs;
  mbedtls_pk_context* _private_key;
};

// Although it's a resource we never actually wait on a MbedTLSSocket, preferring
// to wait on the underlying TCP socket.
class MbedTLSSocket : public BaseMbedTLSSocket {
 public:
  TAG(MbedTLSSocket);
  explicit MbedTLSSocket(MbedTLSResourceGroup* group);
  ~MbedTLSSocket();

  Object* get_clear_outgoing();

  virtual bool init(const char*);

  void set_incoming(Object* incoming, int from) {
    _incoming_packet = incoming;
    _incoming_from = from;
  }

  void set_outgoing(Object* outgoing, int fullness) {
    _outgoing_packet = outgoing;
    _outgoing_fullness = fullness;
  }

  int outgoing_fullness() const { return _outgoing_fullness; }
  void set_outgoing_fullness(int f) { _outgoing_fullness = f; }
  int from() const { return _incoming_from; }
  void set_from(int f) { _incoming_from = f; }
  Object* outgoing_packet() const { return *_outgoing_packet; }
  Object* incoming_packet() const { return *_incoming_packet; }

 private:
  HeapRoot _outgoing_packet; // Blob-compatible or null.
  int _outgoing_fullness;
  HeapRoot _incoming_packet;  // Blob-compatible or null.
  int _incoming_from;
};

class MbedTLSResourceGroup : public ResourceGroup {
 public:
  enum Mode {
    TLS_CLIENT,
    TLS_SERVER
  };

  TAG(MbedTLSResourceGroup);
  MbedTLSResourceGroup(Process* process, TLSEventSource* event_source, Mode mode)
    : ResourceGroup(process, event_source)
    , _mode(mode)
    , _error_flags(0)
    , _error_depth(0)
    , _error_issuer(null) {
  }

  ~MbedTLSResourceGroup() {
    free(_error_issuer);
    _error_issuer = null;
    uninit();
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

  int init();
  void uninit();

  Object* tls_socket_create(Process* process, const char* hostname);
  Object* tls_handshake(Process* process, TLSSocket* socket);

  int verify_callback(mbedtls_x509_crt* cert, int certificate_depth, uint32_t* flags);

  uint32_t error_flags() const { return _error_flags; }
  int error_depth() const { return _error_depth; }
  char* error_issuer() const { return _error_issuer; }
  void clear_error_flags() {
    _error_flags = 0;
    _error_depth = 0;
    free(_error_issuer);
    _error_issuer = null;
  }
 private:
  void init_conf(mbedtls_ssl_config* conf);
  mbedtls_entropy_context _entropy;
  mbedtls_ctr_drbg_context _ctr_drbg;
  Mode _mode;
  uint32_t _error_flags;
  int _error_depth;
  char* _error_issuer;

  friend class BaseMbedTLSSocket;
  friend class MbedTLSSocket;
};

class SslSession {
 public:
  static const int OK = 0;
  static const int OUT_OF_MEMORY = 1;
  static const int CORRUPT = 2;

  // Takes a deep copy of the ssl session provided by MbedTLS.  Returns OK or OUT_OF_MEMORY.
  static int serialize(mbedtls_ssl_session* session, Blob* blob_return);

  // Recreate from a series of bytes.  Returns one of the above status integers.
  static int deserialize(Blob serialized, mbedtls_ssl_session* destination);

  // Call after deserialize.
  static void free_session(mbedtls_ssl_session* session);

 private:
  SslSession(uint8* data) : data_(data) {}
  int serialize(mbedtls_ssl_session* session, size_t struct_size, size_t cert_size, size_t ticket_size);
  int deserialize(word serialized_length, mbedtls_ssl_session* destination);

  int struct_size() const {
    return *reinterpret_cast<const uint16_t*>(data_);
  }
  void set_struct_size(size_t size) {
    *reinterpret_cast<uint16_t*>(data_) = size;
  }
  uint8* struct_address() {
    return data_ + 6;
  }

  int cert_size() const {
    return *reinterpret_cast<const uint16_t*>(data_ + 2);
  }
  void set_cert_size(size_t size) {
    *reinterpret_cast<uint16_t*>(data_ + 2) = size;
  }
  uint8* cert_address() {
    return struct_address() + struct_size();
  }

  int ticket_size() const {
    return *reinterpret_cast<const uint16_t*>(data_ + 4);
  }
  void set_ticket_size(size_t size) {
    *reinterpret_cast<uint16_t*>(data_ + 4) = size;
  }
  uint8* ticket_address() {
    return cert_address() + cert_size();
  }

  // Byte size   Contents.
  // 2           struct_size
  // 2           cert_size
  // 2           ticket_size
  // struct_size struct
  // cert_size   cert (raw)
  // ticket_size ticket
  uint8* data_;
};

} // namespace toit
