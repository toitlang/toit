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

class MbedTlsResourceGroup;
class MbedTlsSocket;
class X509Certificate;

// These numbers must stay in sync with constants in aes.toit.
enum AeadAlgorithmType {
  ALGORITHM_AES_GCM = 0,
  ALGORITHM_CHACHA20_POLY1305 = 1,
  NUMBER_OF_ALGORITHM_TYPES = 2
};

Object* tls_error(MbedTlsResourceGroup* group, Process* process, int err);
bool ensure_handshake_memory();

enum TLS_STATE {
  TLS_DONE = 1 << 0,
  TLS_WANT_READ = 1 << 1,
  TLS_WANT_WRITE = 1 << 2,
  TLS_SENT_HELLO_VERIFY = 1 << 3,
};

// Common base for TLS (stream based) and in the future perhaps DTLS (datagram based) sockets.
class BaseMbedTlsSocket : public TlsSocket {
 public:
  BaseMbedTlsSocket(MbedTlsResourceGroup* group);
  ~BaseMbedTlsSocket();

  mbedtls_ssl_context ssl;

  virtual bool init(const char* transport_id) = 0;
  void apply_certs();
  int add_certificate(X509Certificate* cert, const uint8_t* private_key, size_t private_key_length, const uint8_t* password, int password_length);
  int add_root_certificate(X509Certificate* cert);
  void uninit_certs();
  word handshake() override;

 protected:
  mbedtls_ssl_config conf_;

 private:
  mbedtls_x509_crt* root_certs_;
  mbedtls_pk_context* private_key_;
};

// Although it's a resource we never actually wait on a MbedTlsSocket, preferring
// to wait on the underlying TCP socket.
class MbedTlsSocket : public BaseMbedTlsSocket {
 public:
  TAG(MbedTlsSocket);
  explicit MbedTlsSocket(MbedTlsResourceGroup* group);
  ~MbedTlsSocket();

  Object* get_clear_outgoing();

  virtual bool init(const char*);

  void set_incoming(Object* incoming, int from) {
    incoming_packet_ = incoming;
    incoming_from_ = from;
  }

  void set_outgoing(Object* outgoing, int fullness) {
    outgoing_packet_ = outgoing;
    outgoing_fullness_ = fullness;
  }

  int outgoing_fullness() const { return outgoing_fullness_; }
  void set_outgoing_fullness(int f) { outgoing_fullness_ = f; }
  int from() const { return incoming_from_; }
  void set_from(int f) { incoming_from_ = f; }
  Object* outgoing_packet() const { return *outgoing_packet_; }
  Object* incoming_packet() const { return *incoming_packet_; }

 private:
  HeapRoot outgoing_packet_; // Blob-compatible or null.
  int outgoing_fullness_;
  HeapRoot incoming_packet_;  // Blob-compatible or null.
  int incoming_from_;
};

class MbedTlsResourceGroup : public ResourceGroup {
 public:
  enum Mode {
    TLS_CLIENT,
    TLS_SERVER
  };

  TAG(MbedTlsResourceGroup);
  MbedTlsResourceGroup(Process* process, TlsEventSource* event_source, Mode mode)
    : ResourceGroup(process, event_source)
    , mode_(mode)
    , error_flags_(0)
    , error_depth_(0)
    , error_issuer_(null) {}

  ~MbedTlsResourceGroup() {
    free(error_issuer_);
    error_issuer_ = null;
    uninit();
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

  int init();
  void uninit();

  Object* tls_socket_create(Process* process, const char* hostname);
  Object* tls_handshake(Process* process, TlsSocket* socket);

  int verify_callback(mbedtls_x509_crt* cert, int certificate_depth, uint32_t* flags);

  uint32_t error_flags() const { return error_flags_; }
  int error_depth() const { return error_depth_; }
  char* error_issuer() const { return error_issuer_; }
  void clear_error_flags() {
    error_flags_ = 0;
    error_depth_ = 0;
    free(error_issuer_);
    error_issuer_ = null;
  }
 private:
  void init_conf(mbedtls_ssl_config* conf);
  mbedtls_entropy_context entropy_;
  mbedtls_ctr_drbg_context ctr_drbg_;
  Mode mode_;
  uint32_t error_flags_;
  int error_depth_;
  char* error_issuer_;

  friend class BaseMbedTlsSocket;
  friend class MbedTlsSocket;
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
