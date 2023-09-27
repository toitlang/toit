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
#include <mbedtls/gcm.h>
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
class BaseMbedTlsSocket;
class X509Certificate;

// These numbers must stay in sync with constants in aes.toit.
enum AeadAlgorithmType {
  ALGORITHM_AES_GCM = 0,
  ALGORITHM_CHACHA20_POLY1305 = 1,
  NUMBER_OF_ALGORITHM_TYPES = 2
};

Object* tls_error(BaseMbedTlsSocket* group, Process* process, int err);
bool ensure_handshake_memory();

enum TLS_STATE {
  TLS_DONE = 1 << 0,
  TLS_WANT_READ = 1 << 1,
  TLS_WANT_WRITE = 1 << 2,
  TLS_SENT_HELLO_VERIFY = 1 << 3,
};

bool is_tls_malloc_failure(int err);

// Common base for TLS (stream based) and in the future perhaps DTLS (datagram based) sockets.
class BaseMbedTlsSocket : public TlsSocket {
 public:
  BaseMbedTlsSocket(MbedTlsResourceGroup* group);
  ~BaseMbedTlsSocket();

  mbedtls_ssl_context ssl;

  virtual bool init() = 0;
  void apply_certs(Process* process);
  int add_certificate(X509Certificate* cert, const uint8_t* private_key, size_t private_key_length, const uint8_t* password, int password_length);
  int add_root_certificate(X509Certificate* cert);
  void register_root_callback();
  void uninit_certs();
  word handshake() override;

  int verify_callback(mbedtls_x509_crt* cert, int certificate_depth, uint32_t* flags);

  void record_unknown_issuer(const mbedtls_asn1_named_data* issuer);
  // Hash a textual description of the issuer of a certificate, or the
  // subject of a root certificate. These should match.
  static uint32 hash_subject(uint8* buffer, int length);
  uint32_t error_flags() const { return error_flags_; }
  char* error_issuer() const { return error_issuer_; }
  void clear_error_flags() {
    error_flags_ = 0;
    free(error_issuer_);
    error_issuer_ = null;
  }

 protected:
  mbedtls_ssl_config conf_;

 private:
  mbedtls_x509_crt* root_certs_;
  mbedtls_pk_context* private_key_;
  uint32_t error_flags_;
  char* error_issuer_;
};

// A size that should be plenty for all known root certificates, but won't overflow the stack.
static const int MAX_SUBJECT = 400;

// Although it's a resource we never actually wait on a MbedTlsSocket, preferring
// to wait on the underlying TCP socket.
class MbedTlsSocket : public BaseMbedTlsSocket {
 public:
  TAG(MbedTlsSocket);
  explicit MbedTlsSocket(MbedTlsResourceGroup* group);
  ~MbedTlsSocket();

  Object* get_clear_outgoing();

  virtual bool init();

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
      , mode_(mode) {}

  ~MbedTlsResourceGroup() {
    uninit();
  }

  uint32_t on_event(Resource* resource, word data, uint32_t state) override;

  int init();
  void uninit();

  Object* tls_socket_create(Process* process, const char* hostname);
  Object* tls_handshake(Process* process, TlsSocket* socket);

  mbedtls_entropy_context* entropy() { return &entropy_; }

 private:
  void init_conf(mbedtls_ssl_config* conf);
  mbedtls_entropy_context entropy_;
  mbedtls_ctr_drbg_context ctr_drbg_;
  Mode mode_;

  friend class BaseMbedTlsSocket;
  friend class MbedTlsSocket;
};

} // namespace toit
