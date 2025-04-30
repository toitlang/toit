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

#define MBEDTLS_ALLOW_PRIVATE_ACCESS
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

#if defined(TOIT_ESP32)
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

const int ISSUER_DETAIL = 0;
const int SUBJECT_DETAIL = 1;
const int ERROR_DETAILS = 2;

// Common base for TLS (stream based) and in the future perhaps DTLS (datagram based) sockets.
class BaseMbedTlsSocket : public TlsSocket {
 public:
  BaseMbedTlsSocket(MbedTlsResourceGroup* group);
  ~BaseMbedTlsSocket();

  mbedtls_ssl_context ssl;

  virtual bool init() = 0;
  void apply_certs(Process* process);
  void disable_certificate_validation();
  int add_certificate(X509Certificate* cert, const uint8_t* private_key, size_t private_key_length, const uint8_t* password, int password_length);
  int add_root_certificate(X509Certificate* cert);
  void register_root_callback();
  void uninit_certs();
  word handshake() override;

  int verify_callback(mbedtls_x509_crt* cert, int certificate_depth, uint32_t* flags);

  void record_error_detail(const mbedtls_asn1_named_data* issuer, int flags, int index);
  // Hash a textual description of the issuer of a certificate, or the
  // subject of a root certificate. These should match.
  static uint32 hash_subject(uint8* buffer, word length);
  uint32_t error_flags() const { return error_flags_; }
  char* error_detail(int index) const { return error_details_[index]; }
  void clear_error_data();

 protected:
  mbedtls_ssl_config conf_;

 private:
  mbedtls_x509_crt* root_certs_;
  mbedtls_pk_context* private_key_;
  uint32_t error_flags_;
  char* error_details_[ERROR_DETAILS];
};

// A size that should be plenty for all known root certificates, but won't overflow the stack.
static const int MAX_SUBJECT = 400;

// Although it's a resource, we never actually wait on a MbedTlsSocket,
// preferring to wait on the underlying TCP socket.
class MbedTlsSocket : public BaseMbedTlsSocket {
 public:
  TAG(MbedTlsSocket);
  explicit MbedTlsSocket(MbedTlsResourceGroup* group);
  ~MbedTlsSocket();

  virtual bool init();

  void set_incoming(uint8* data, uword length) {
    if (incoming_packet_) {
      free(incoming_packet_);
    }
    incoming_packet_ = data;
    incoming_from_ = 0;
    incoming_length_ = length;
  }

  int outgoing_fullness() const { return outgoing_fullness_; }
  void set_outgoing_fullness(int f) { outgoing_fullness_ = f; }
  int from() const { return incoming_from_; }
  void set_from(int f) { incoming_from_ = f; }
  uint8* outgoing_buffer() { return outgoing_buffer_; }
  uword incoming_length() const { return incoming_length_; }
  const uint8* incoming_packet() const { return incoming_packet_; }
  static const int OUTGOING_BUFFER_SIZE = 1500;

 private:
  uint8 outgoing_buffer_[OUTGOING_BUFFER_SIZE];
  int outgoing_fullness_ = 0;
  uint8* incoming_packet_ = null;
  uword incoming_length_ = 0;
  uword incoming_from_ = 0;
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
