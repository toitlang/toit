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

#include "../top.h"

#if !defined(TOIT_FREERTOS) || CONFIG_TOIT_CRYPTO
#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include <mbedtls/chachapoly.h>
#include <mbedtls/error.h>
#include <mbedtls/gcm.h>
#include <mbedtls/oid.h>
#include <mbedtls/pem.h>
#include <mbedtls/platform.h>
#if MBEDTLS_VERSION_MAJOR >= 3
#include <../library/ssl_misc.h>
#include <mbedtls/cipher.h>
#else
#include <mbedtls/ssl_internal.h>
#endif

#ifdef TOIT_WINDOWS
#include <windows.h>
#include <wincrypt.h>
#endif

#include "../entropy_mixer.h"
#include "../heap_report.h"
#include "../primitive.h"
#include "../process.h"
#include "../objects_inline.h"
#include "../resource.h"
#include "../scheduler.h"
#include "../vm.h"

#include "tls.h"
#include "x509.h"

namespace toit {

void MbedTlsResourceGroup::uninit() {
  mbedtls_ctr_drbg_free(&ctr_drbg_);
  mbedtls_entropy_free(&entropy_);
}

void BaseMbedTlsSocket::uninit_certs() {
  if (private_key_ != null) mbedtls_pk_free(private_key_);
  delete private_key_;
  private_key_ = null;
}

#if MBEDTLS_VERSION_MAJOR >= 3
static int random_generator(void* arg, unsigned char* output, size_t len) {
  auto mixer = reinterpret_cast<EntropyMixer*>(arg);
  return mixer->get_entropy(output, len);
}
#endif

int BaseMbedTlsSocket::add_certificate(X509Certificate* cert, const uint8_t* private_key, size_t private_key_length, const uint8_t* password, int password_length) {
  uninit_certs();  // Remove any old cert on the config.

  private_key_ = _new mbedtls_pk_context;
  if (!private_key_) return MBEDTLS_ERR_PK_ALLOC_FAILED;
  mbedtls_pk_init(private_key_);
#if MBEDTLS_VERSION_MAJOR >= 3
  // We need a random number generator to blind the calculations in the RSA, to
  // avoid timing attacks.
  void* random_arg = reinterpret_cast<void*>(EntropyMixer::instance());
  int ret = mbedtls_pk_parse_key(private_key_, private_key, private_key_length, password, password_length, random_generator, random_arg);
#else
  int ret = mbedtls_pk_parse_key(private_key_, private_key, private_key_length, password, password_length);
#endif
  if (ret < 0) {
    delete private_key_;
    private_key_ = null;
    return ret;
  }

  ret = mbedtls_ssl_conf_own_cert(&conf_, cert->cert(), private_key_);
  return ret;
}

int BaseMbedTlsSocket::add_root_certificate(X509Certificate* cert) {
  // Copy to a per-socket chain.
  mbedtls_x509_crt** last = &root_certs_;
  // Move to end of chain.
  while (*last != null) last = &(*last)->next;
  ASSERT(!cert->cert()->next);
  // Do a shallow copy of the cert.
  *last = _new mbedtls_x509_crt(*(cert->cert()));
  if (*last == null) return MBEDTLS_ERR_PK_ALLOC_FAILED;
  // By default we don't enable certificate verification in server mode, but if
  // the user adds a root that indicates that they certainly want verification.
  mbedtls_ssl_conf_authmode(&conf_, MBEDTLS_SSL_VERIFY_REQUIRED);
  return 0;
}

uint32 BaseMbedTlsSocket::hash_subject(uint8* buffer, word length) {
  // Matching should be case independent for ASCII strings, so lets just zap
  // all the 0x20 bits, since we are just doing a fuzzy match.
  for (word i = 0; i < length; i++) buffer[i] |= 0x20;
  return Utils::crc32(0xce77509, buffer, length);
}

static void* tagging_mbedtls_calloc(size_t nelem, size_t size) {
  // Sanity check inputs for security.
  if (nelem > 0xffff || size > 0xffff) return null;
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + BIGNUM_MALLOC_TAG);
  size_t total_size = nelem * size;
  void* result = calloc(1, total_size);
  if (!result) {
    VM::current()->scheduler()->gc(null, /* malloc_failed = */ true, /* try_hard = */ true);
    result = calloc(1, total_size);
  }
  return result;
}

static void tagging_mbedtls_free(void* address) {
  free(address);
}

// Use the unparsed certificates on the process to find the right one
// for this connection.
static int toit_tls_find_root(void* context, const mbedtls_x509_crt* certificate, mbedtls_x509_crt** chain) {
  BaseMbedTlsSocket* socket = unvoid_cast<BaseMbedTlsSocket*>(context);
  Process* process = socket->resource_group()->process();

  uint8 issuer_buffer[MAX_SUBJECT];
  int ret = mbedtls_x509_dn_gets(char_cast(&issuer_buffer[0]), MAX_SUBJECT, &certificate->issuer);
  if (ret < 0) goto failed;
  if (ret >= MAX_SUBJECT) {
    ret = MBEDTLS_ERR_ASN1_BUF_TOO_SMALL;
    goto failed;
  } else {
    uint32 issuer_hash = BaseMbedTlsSocket::hash_subject(issuer_buffer, ret);

    *chain = null;
    mbedtls_x509_crt cert;
    mbedtls_x509_crt_init(&cert);
    mbedtls_x509_crt** last = chain;
    bool found_root_with_matching_subject = false;
    Locker locker(OS::tls_mutex());
    for (auto unparsed : process->root_certificates(locker)) {
      if (unparsed->subject_hash() != issuer_hash) continue;
      auto cert = unvoid_cast<mbedtls_x509_crt*>(tagging_mbedtls_calloc(1, sizeof(mbedtls_x509_crt)));
      if (!cert) {
        ret = MBEDTLS_ERR_X509_ALLOC_FAILED;
        goto failed;
      }

      mbedtls_x509_crt_init(cert);
      if (X509ResourceGroup::is_pem_format(unparsed->data(), unparsed->length())) {
        ret = mbedtls_x509_crt_parse(cert, unparsed->data(), unparsed->length());
      } else {
        ret = mbedtls_x509_crt_parse_der_nocopy(cert, unparsed->data(), unparsed->length());
      }
      if (ret != 0) goto failed;
      found_root_with_matching_subject = true;
      *last = cert;
      last = &cert->next;
      // We could break here, but a CRC32 checksum is not collision proof, so we had
      // better keep going in case there's a different cert with the same checksum.
    }
    if (!found_root_with_matching_subject) {
      socket->record_error_detail(&certificate->issuer, MBEDTLS_X509_BADCERT_NOT_TRUSTED, ISSUER_DETAIL);
      socket->record_error_detail(&certificate->subject, MBEDTLS_X509_BADCERT_NOT_TRUSTED, SUBJECT_DETAIL);
    }
    return 0;  // No error (but perhaps no certificate was found).
  }

failed:
  for (mbedtls_x509_crt* cert = *chain; cert; ) {
    mbedtls_x509_crt* next = cert->next;
    mbedtls_x509_crt_free(cert);
    tagging_mbedtls_free(cert);
    cert = next;
  }
  return ret;  // Problem.  Sadly, this is discarded unless you have a patched MbedTLS.
}

void BaseMbedTlsSocket::apply_certs(Process* process) {
  if (root_certs_) {
    mbedtls_ssl_conf_ca_chain(&conf_, root_certs_, null);
  } else {
    mbedtls_ssl_conf_ca_cb(&conf_, toit_tls_find_root, void_cast(this));
  }
}

void BaseMbedTlsSocket::disable_certificate_validation() {
  mbedtls_ssl_conf_authmode(&conf_, MBEDTLS_SSL_VERIFY_NONE);
}

word BaseMbedTlsSocket::handshake() {
  return mbedtls_ssl_handshake(&ssl);
}

#ifdef DEBUG_TLS
static void debug_printer(void* ctx, int level, const char* file, int line, const char* str) {
  printf("%s:%04d: %s", file, line, str);
}
#endif

static int toit_tls_verify(
    void* ctx,
    mbedtls_x509_crt* cert,
    int certificate_depth,  // Counts up to trusted root.
    uint32_t* flags) {      // Flags for this cert.
  auto socket = unvoid_cast<MbedTlsSocket*>(ctx);
  return socket->verify_callback(cert, certificate_depth, flags);
}

int BaseMbedTlsSocket::verify_callback(mbedtls_x509_crt* crt, int certificate_depth, uint32_t* flags) {
  if (*flags != 0) {
    if ((*flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED) != 0) {
      // This is the error when the cert relies on a root that we have not
      // trusted/added.
      record_error_detail(&crt->issuer, *flags, ISSUER_DETAIL);
    }
    record_error_detail(&crt->subject, *flags, SUBJECT_DETAIL);
  }
  return 0; // Keep going.
}

void BaseMbedTlsSocket::record_error_detail(const mbedtls_asn1_named_data* issuer, int error_flags, int index) {
  char buffer[MAX_SUBJECT];
  int ret = mbedtls_x509_dn_gets(buffer, MAX_SUBJECT, issuer);
  free(error_details_[index]);
  error_details_[index] = null;
  if (ret > 0 && ret < MAX_SUBJECT) {
    // If we are unlucky and the malloc fails, then the error message will
    // be less informative.
    char* text = unvoid_cast<char*>(malloc(ret + 1));
    if (text) {
      memcpy(text, buffer, ret);
      text[ret] = '\0';
      error_details_[index] = text;
    }
  }
  error_flags_ = error_flags;
}

void BaseMbedTlsSocket::clear_error_data() {
  error_flags_ = 0;
  for (int i = 0; i < ERROR_DETAILS; i++) {
    free(error_details_[i]);
    error_details_[i] = null;
  }
}

void MbedTlsResourceGroup::init_conf(mbedtls_ssl_config* conf) {
  mbedtls_platform_set_calloc_free(tagging_mbedtls_calloc, tagging_mbedtls_free);
  mbedtls_ssl_config_init(conf);
  mbedtls_ssl_conf_rng(conf, mbedtls_ctr_drbg_random, &ctr_drbg_);
  auto transport = MBEDTLS_SSL_TRANSPORT_STREAM;
  auto client_server = (mode_ == TLS_SERVER) ? MBEDTLS_SSL_IS_SERVER : MBEDTLS_SSL_IS_CLIENT;

  // This enables certificate verification in client mode, but does not
  // enable it in server mode.
  if (int ret = mbedtls_ssl_config_defaults(conf,
                                            client_server,
                                            transport,
                                            MBEDTLS_SSL_PRESET_DEFAULT)) {
    FATAL("mbedtls_ssl_config_defaults returned %d", ret);
  }
  mbedtls_ssl_conf_session_tickets(conf, MBEDTLS_SSL_SESSION_TICKETS_ENABLED);

#ifdef DEBUG_TLS
  mbedtls_ssl_conf_dbg(conf, debug_printer, 0);
  mbedtls_debug_set_threshold(2);
#endif

  mbedtls_ssl_conf_max_frag_len(conf, MBEDTLS_SSL_MAX_FRAG_LEN_4096);
}

int MbedTlsResourceGroup::init() {
  mbedtls_ctr_drbg_init(&ctr_drbg_);
  mbedtls_entropy_init(&entropy_);
  int ret = mbedtls_ctr_drbg_seed(&ctr_drbg_, mbedtls_entropy_func, &entropy_, null, 0);
  return ret;
}

uint32_t MbedTlsResourceGroup::on_event(Resource* resource, word data, uint32_t state) {
  if (data == MBEDTLS_ERR_SSL_WANT_READ) {
    return TLS_WANT_READ;
  } else if (data == MBEDTLS_ERR_SSL_WANT_WRITE) {
    return TLS_WANT_WRITE;
  } else if (data == 0) {
    return TLS_DONE;
  } else {
    // Errors are negative.
    return -data;
  }
}

BaseMbedTlsSocket::BaseMbedTlsSocket(MbedTlsResourceGroup* group)
    : TlsSocket(group)
    , root_certs_(null)
    , private_key_(null)
    ,   error_flags_(0) {
  mbedtls_ssl_init(&ssl);
  group->init_conf(&conf_);
  for (int i = 0; i < ERROR_DETAILS; i++) error_details_[i] = null;
}

BaseMbedTlsSocket::~BaseMbedTlsSocket() {
  mbedtls_ssl_free(&ssl);
  uninit_certs();
  mbedtls_ssl_config_free(&conf_);
  for (mbedtls_x509_crt* c = root_certs_; c != null;) {
    mbedtls_x509_crt* n = c->next;
    // We just delete the shallow copy, so there is no need
    // to call mbedtls_x509_crt_free(). The actual freeing
    // is taken care of by the x509 resource destruction.
    delete c;
    c = n;
  }
  clear_error_data();
}

MbedTlsSocket::MbedTlsSocket(MbedTlsResourceGroup* group)
  : BaseMbedTlsSocket(group) {}

MbedTlsSocket::~MbedTlsSocket() {
  free(incoming_packet_);
}

MODULE_IMPLEMENTATION(tls, MODULE_TLS)

bool is_tls_malloc_failure(int err) {
  // For some reason Mbedtls doesn't seem to export this mask.
  static const int MBED_LOW_LEVEL_ERROR_MASK = 0x7f;
  // Error codes are negative so we use or-not instead of and.
  int lo_error = err | ~MBED_LOW_LEVEL_ERROR_MASK;
  int hi_error = err & ~MBED_LOW_LEVEL_ERROR_MASK;
  if (hi_error == MBEDTLS_ERR_CIPHER_ALLOC_FAILED ||
      hi_error == MBEDTLS_ERR_ECP_ALLOC_FAILED ||
      hi_error == MBEDTLS_ERR_MD_ALLOC_FAILED ||
      lo_error == MBEDTLS_ERR_MPI_ALLOC_FAILED ||
      lo_error == MBEDTLS_ERR_ASN1_ALLOC_FAILED ||
      hi_error == MBEDTLS_ERR_PEM_ALLOC_FAILED ||
      hi_error == MBEDTLS_ERR_PK_ALLOC_FAILED ||
      hi_error == MBEDTLS_ERR_SSL_ALLOC_FAILED ||
      hi_error == MBEDTLS_ERR_X509_ALLOC_FAILED) {
    return true;
  }
  return false;
}

// None of the below messages can be longer than this.
static size_t MAX_CERT_ERROR_LENGTH = 20;

static const char* CERT_ERRORS[] = {
  "EXPIRED",
  "REVOKED",
  "CN_MISMATCH",
  "NOT_TRUSTED",
  "CRL_NOT_TRUSTED",
  "CRL_EXPIRED",
  "MISSING",
  "SKIP_VERIFY",
  "OTHER",
  "FUTURE",
  "CRL_FUTURE",
  "KEY_USAGE",
  "EXT_KEY_USAGE",
  "NS_CERT_TYPE",
  "BAD_MD",
  "BAD_PK",
  "BAD_KEY",
  "CRL_MAD_MD",
  "CRL_BAD_PK",
  "CRL_BAD_KEY",
  null
};

Object* tls_error(BaseMbedTlsSocket* socket, Process* process, int err) {
  if (is_tls_malloc_failure(err)) {
    FAIL(MALLOC_FAILED);
  }
  static const size_t BUFFER_LEN = 400;
  char buffer[BUFFER_LEN];
  const char* issuer = socket ? socket->error_detail(ISSUER_DETAIL) : "";
  int flags = socket ? socket->error_flags() : 0;
  if (err == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED &&
      socket &&
      flags) {
    bool print_issuer = issuer && ((flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED) != 0);
    const char* subject = socket->error_detail(SUBJECT_DETAIL);
    size_t len = 0;
    if (print_issuer) {
      if (subject) {
        len = snprintf(buffer,
                       BUFFER_LEN - 1,
                       "Unknown root certificate: '%s'\nCertificate error 0x%04x: '%s'",
                       issuer,
                       flags,
                       subject);
      } else {
        len = snprintf(buffer, BUFFER_LEN - 1, "Unknown root certificate: '%s'", issuer);
      }
    } else if (subject) {
      len = snprintf(buffer, BUFFER_LEN - 1, "Certificate error 0x%x: '%s'", flags, subject);
    }
    while (flags != 0) {
      if (!len || BUFFER_LEN - len < MAX_CERT_ERROR_LENGTH) break;
      for (int i = 0; CERT_ERRORS[i]; i++) {
        if ((flags & (1 << i)) != 0) {
          flags &= ~(1 << i);
          len += snprintf(buffer + len, BUFFER_LEN - len - 1, "\n%s", CERT_ERRORS[i]);
          buffer[len] = '\0';
          // Only add one at a time before checking space requirement.
          break;
        }
      }
    }
    if (len > 0 && len < BUFFER_LEN) {
      buffer[len] = '\0';
      if (!Utils::is_valid_utf_8(unsigned_cast(buffer), len)) {
        for (unsigned i = 0; i < len; i++) if (buffer[i] & 0x80) buffer[i] = '.';
      }
      String* str = process->allocate_string(buffer);
      if (str == null) FAIL(ALLOCATION_FAILED);
      socket->clear_error_data();
      return Primitive::mark_as_error(str);
    }
  }
  if (((-err) & 0xff80) == -MBEDTLS_ERR_SSL_CA_CHAIN_REQUIRED) {
    strncpy(buffer, "No root certificate provided.\n", BUFFER_LEN);
  }
#ifdef TOIT_FREERTOS
  // On small platforms we don't want to pay the 14k to have all the error
  // messages from MbedTLS, so we just print the code and a link to the
  // explanation.
  else if (err < 0) {
    int major = (-err) & 0xff80;
    int minor = (-err) & ~0xff80;
    const char* gist = "https://gist.github.com/erikcorry/b25bdcacf3e0086f8a2afb688420678e";
    if (minor == 0) {
      snprintf(buffer, BUFFER_LEN, "Mbedtls high level error 0x%04x - see %s", major, gist);
    } else {
      snprintf(buffer, BUFFER_LEN, "Mbedtls high level error 0x%04x, low level error 0x%04x - see %s", major, minor, gist);
    }
  } else {
    snprintf(buffer, BUFFER_LEN, "Unknown mbedtls error 0x%x", err);
  }
#else
  else {
    mbedtls_strerror(err, buffer, BUFFER_LEN);
  }
#endif
  unsigned used = strlen(buffer);
  if (socket && socket->error_flags() != 0 && used < BUFFER_LEN - 30) {
    buffer[used] = ':';
    buffer[used + 1] = ' ';
    buffer[used + 2] = '\0';
    used += 2;
    mbedtls_x509_crt_verify_info(buffer + used, BUFFER_LEN - used, " * ", socket->error_flags());
    used = strlen(buffer);
    if (used && buffer[used - 1] == '\n') {
      used--;
      buffer[used] = '\0';
    }
  }
  buffer[BUFFER_LEN - 1] = '\0';
  String* str = process->allocate_string(buffer);
  if (str == null) FAIL(ALLOCATION_FAILED);
  if (socket) socket->clear_error_data();
  return Primitive::mark_as_error(str);
}

PRIMITIVE(take_outgoing) {
  ARGS(MbedTlsSocket, socket);
  Locker locker(OS::tls_mutex());

  ByteArray* array = process->allocate_byte_array(socket->outgoing_fullness());
  if (array == null) FAIL(ALLOCATION_FAILED);
  ByteArray::Bytes data_bytes(array);
  memcpy(data_bytes.address(), socket->outgoing_buffer(), data_bytes.length());
  socket->set_outgoing_fullness(0);
  return array;
}

PRIMITIVE(set_incoming) {
  ARGS(MbedTlsSocket, socket, Object, incoming, int, from);
  Blob blob;
  if (!incoming->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) FAIL(WRONG_OBJECT_TYPE);
  uword length = blob.length() - from;
  uint8* address;
  if (from < 0 || from > blob.length()) FAIL(INVALID_ARGUMENT);
  // is_byte_array is quite strict.  For example, COW byte arrays are not
  // byte arrays.
  if (is_byte_array(incoming) && ByteArray::cast(incoming)->has_external_address()) {
    // We need to neuter the byte array and steal its external data.
    address = const_cast<uint8*>(blob.address()) + from;
    ByteArray::cast(incoming)->neuter(process);
  } else {
    // We need to take a copy of the incoming.
    address = reinterpret_cast<uint8*>(malloc(length));
    if (address == null) FAIL(MALLOC_FAILED);
    memcpy(address, blob.address() + from, length);
  }
  socket->set_incoming(address + from, length);
  return process->null_object();
}

PRIMITIVE(init) {
  ARGS(bool, server)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  // Mark usage. When the group is unregistered, the usage is automatically
  // decremented, but if group allocation fails, we manually call unuse().
  TlsEventSource* tls = TlsEventSource::instance();
  if (!tls->use()) FAIL(MALLOC_FAILED);

  auto mode = server ? MbedTlsResourceGroup::TLS_SERVER : MbedTlsResourceGroup::TLS_CLIENT;
  MbedTlsResourceGroup* group = _new MbedTlsResourceGroup(process, tls, mode);
  if (!group) {
    tls->unuse();
    FAIL(MALLOC_FAILED);
  }

  int ret = group->init();
  if (ret != 0) {
    group->tear_down();
    return tls_error(null, process, ret);
  }

  proxy->set_external_address(group);
  return proxy;
}

PRIMITIVE(deinit) {
  ARGS(MbedTlsResourceGroup, group);
  group->tear_down();
  group_proxy->clear_external_address();
  return process->null_object();
}

Object* MbedTlsResourceGroup::tls_socket_create(Process* process, const char* hostname) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  MbedTlsSocket* socket = _new MbedTlsSocket(this);

  if (socket == null) FAIL(MALLOC_FAILED);
  proxy->set_external_address(socket);

  mbedtls_ssl_set_hostname(&socket->ssl, hostname);
  register_resource(socket);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(MbedTlsResourceGroup, resource_group, cstring, hostname);

  return resource_group->tls_socket_create(process, hostname);
}

PRIMITIVE(handshake) {
  ARGS(MbedTlsSocket, socket);
  TlsEventSource::instance()->handshake(socket);
  return process->null_object();
}

// This is only used after the handshake.  It reads data that has been decrypted.
// Normally returns a byte array.
// MbedTLS may need more data to be input (buffered) before it can return any
// decrypted data.  In that case we return TLS_WANT_READ.
// If the connection is closed, returns null.
PRIMITIVE(read)  {
  ARGS(MbedTlsSocket, socket);

  // Process data and read available size, before allocating buffer.
  if (mbedtls_ssl_read(&socket->ssl, null, 0) == MBEDTLS_ERR_SSL_WANT_READ) {
    // Early return to avoid allocation when no data is available.
    return Smi::from(TLS_WANT_READ);
  }
  int size = mbedtls_ssl_get_bytes_avail(&socket->ssl);
  if (size < 0 || size > ByteArray::PREFERRED_IO_BUFFER_SIZE) size = ByteArray::PREFERRED_IO_BUFFER_SIZE;

  ByteArray* array = process->allocate_byte_array(size, /*force_external*/ true);
  if (array == null) FAIL(ALLOCATION_FAILED);
  int read = mbedtls_ssl_read(&socket->ssl, ByteArray::Bytes(array).address(), size);
  if (read == 0 || read == MBEDTLS_ERR_SSL_CONN_EOF || read == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
    return process->null_object();
  } else if (read == MBEDTLS_ERR_SSL_WANT_READ) {
    return Smi::from(TLS_WANT_READ);
  } else if (read < 0) {
    return tls_error(socket, process, read);
  }

  array->resize_external(process, read);
  return array;
}

// This is only used after the handshake.  It reads data that has been decrypted.
// Normally returns a byte array.
// MbedTLS may need more data to be input (buffered) before it can return any
// decrypted data.  In that case we return TLS_WANT_READ, an integer.
// If the connection is closed, returns null.
PRIMITIVE(write) {
  ARGS(MbedTlsSocket, socket, Blob, data, int, from, int, to)

  if (from < 0 || from > to || to > data.length()) FAIL(OUT_OF_RANGE);

  int wrote = mbedtls_ssl_write(&socket->ssl, data.address() + from, to - from);
  if (wrote < 0) {
    if (wrote == MBEDTLS_ERR_SSL_WANT_WRITE) {
      wrote = 0;
    } else {
      return tls_error(socket, process, wrote);
    }
  }

  return Smi::from(wrote);
}

PRIMITIVE(close_write) {
  ARGS(MbedTlsSocket, socket);

  mbedtls_ssl_close_notify(&socket->ssl);

  return process->null_object();
}

PRIMITIVE(close) {
  ARGS(MbedTlsSocket, socket);
  TlsEventSource::instance()->close(socket);

  socket_proxy->clear_external_address();

  return process->null_object();
}

static const int NEEDS_DELETE = 1;
static const int IN_FLASH = 2;
static const int IGNORE_UNSUPPORTED_HASH = 4;

static Object* add_global_root(const uint8* data, size_t length, Object* hash, Process* process, int flags);

#ifdef TOIT_WINDOWS
static Object* add_roots_from_store(const HCERTSTORE store, Process* process) {
  if (!store) return process->null_object();
  const CERT_CONTEXT* cert_context = CertEnumCertificatesInStore(store, null);
  while (cert_context) {
    if (cert_context->dwCertEncodingType == X509_ASN_ENCODING) {
      // The certificate is in DER format.
      const uint8* data = cert_context->pbCertEncoded;
      size_t size = cert_context->cbCertEncoded;
      Object* result = add_global_root(data, size, process->null_object(), process, IGNORE_UNSUPPORTED_HASH);
      // Normally the result is a hash, but we don't need that here, so just
      // check for errors.
      if (Primitive::is_error(result)) return result;
    }
    cert_context = CertEnumCertificatesInStore(store, cert_context);
  }
  return process->null_object();
}

static Object* load_system_trusted_roots(Process* process) {
  const HCERTSTORE root_store = CertOpenStore(CERT_STORE_PROV_SYSTEM, 0, 0, CERT_SYSTEM_STORE_CURRENT_USER, L"ROOT");
  Object* result = add_roots_from_store(root_store, process);
  if (Primitive::is_error(result)) return result;

  const HCERTSTORE ca_store = CertOpenStore(CERT_STORE_PROV_SYSTEM, 0, 0, CERT_SYSTEM_STORE_CURRENT_USER, L"CA");
  return add_roots_from_store(ca_store, process);
}
#endif

PRIMITIVE(use_system_trusted_root_certificates) {
#ifdef TOIT_WINDOWS
  static bool loaded_system_trusted_roots = false;
  bool load = false;
  { Locker locker(OS::tls_mutex());
    load = !loaded_system_trusted_roots;
  }
  if (load) {
    Object* result = load_system_trusted_roots(process);
    if (Primitive::is_error(result)) return result;
    loaded_system_trusted_roots = true;
  }
  { Locker locker(OS::tls_mutex());
    loaded_system_trusted_roots = true;
  }
#endif
  return process->null_object();
}

PRIMITIVE(add_global_root_certificate) {
  ARGS(Object, unparsed_cert, Object, hash);
  bool needs_delete = false;
  const uint8* data = null;
  size_t length = 0;

  Object* result = X509ResourceGroup::get_certificate_data(process, unparsed_cert, &needs_delete, &data, &length);
  if (result) return result;  // Error case.

  bool in_flash = reinterpret_cast<const HeapObject*>(data)->on_program_heap(process);
  ASSERT(!(in_flash && needs_delete));  // We can't free something in flash.
  int flags = 0;
  if (needs_delete) flags |= NEEDS_DELETE;
  if (in_flash) flags |= IN_FLASH;
  return add_global_root(data, length, hash, process, flags);
}

static Object* add_global_root(const uint8* data, size_t length, Object* hash, Process* process, int flags) {
  bool needs_delete = (flags & NEEDS_DELETE) != 0;
  bool in_flash = (flags & IN_FLASH) != 0;
  if (!needs_delete && !in_flash) {
    // The raw cert data will not survive the end of this primitive, so we need a copy.
    uint8* new_data = _new uint8[length];
    if (!new_data) {
      FAIL(MALLOC_FAILED);
    }
    memcpy(new_data, data, length);
    data = new_data;
    needs_delete = true;
  }

  UnparsedRootCertificate* root = _new UnparsedRootCertificate(data, length, needs_delete);
  if (!root) {
    if (needs_delete) delete data;
    FAIL(MALLOC_FAILED);
  }

  DeferDelete<UnparsedRootCertificate> defer_root_delete(root);

  uint32 subject_hash = 0;
  if (hash == process->null_object()) {
    // The global roots are parsed on demand, but we parse them now, then discard
    // the result, to get an early error message and the issuer data so we
    // know when to use it.
    mbedtls_x509_crt cert;
    mbedtls_x509_crt_init(&cert);
    int ret;
    if (X509ResourceGroup::is_pem_format(data, length)) {
      ret = mbedtls_x509_crt_parse(&cert, data, length);
    } else {
      ret = mbedtls_x509_crt_parse_der_nocopy(&cert, data, length);
    }
    if (ret != 0) {
      mbedtls_x509_crt_free(&cert);
      int major_error = (-ret & 0xff80);
      if ((flags & IGNORE_UNSUPPORTED_HASH) != 0 &&
          (-major_error == MBEDTLS_ERR_X509_UNKNOWN_SIG_ALG ||
           -major_error == MBEDTLS_ERR_X509_INVALID_EXTENSIONS ||
           -major_error == MBEDTLS_ERR_ASN1_UNEXPECTED_TAG)) {
        return process->null_object();
      } else {
        return tls_error(null, process, ret);
      }
    }

    uint8 subject_buffer[MAX_SUBJECT];
    ret = mbedtls_x509_dn_gets(char_cast(&subject_buffer[0]), MAX_SUBJECT, &cert.subject);
    mbedtls_x509_crt_free(&cert);
    if (ret < 0 || ret >= MAX_SUBJECT) {
      return tls_error(null, process, ret < 0 ? ret : MBEDTLS_ERR_ASN1_BUF_TOO_SMALL);
    }
    subject_hash = BaseMbedTlsSocket::hash_subject(subject_buffer, ret);
  } else {
    // If the subject hash is given to the primitive then we are probably
    // dealing with a root cert directly from the certificate roots package or
    // baked into the VM. In that case we speed up the initialization by not
    // parsing the cert, and trusting that the hash is correct.
    GET_UINT32(hash, subject_hash_64);
    subject_hash = subject_hash_64;
  }
  root->set_subject_hash(subject_hash);

  // No errors found, so lets add the root cert to the chain on the process.
  { Locker locker(OS::tls_mutex());
    if (!process->already_has_root_certificate(data, length, locker)) {
      defer_root_delete.keep();  // Don't delete it, once it's attached to the process.
      process->add_root_certificate(root, locker);
    }
  }

  return Primitive::integer(subject_hash, process);
}

PRIMITIVE(add_root_certificate) {
  ARGS(BaseMbedTlsSocket, socket, X509Certificate, cert);
  // You can only append a single cert, not a chain of certs.
  if (cert->cert()->next) FAIL(INVALID_ARGUMENT);
  int ret = socket->add_root_certificate(cert);
  if (ret != 0) return tls_error(socket, process, ret);
  return process->null_object();
}

PRIMITIVE(add_certificate) {
  ARGS(BaseMbedTlsSocket, socket, X509Certificate, certificate, blob_or_string_with_terminating_null, private_key, blob_or_string_with_terminating_null, password);

  int ret = socket->add_certificate(certificate, private_key, private_key_length, password, password_length);
  if (ret != 0) return tls_error(socket, process, ret);
  return process->null_object();
}

static int toit_tls_send(void* ctx, const unsigned char* buf, size_t len) {
  Locker locker(OS::tls_mutex());

  auto socket = unvoid_cast<MbedTlsSocket*>(ctx);
  size_t fullness = socket->outgoing_fullness();
  size_t result = Utils::min(len, MbedTlsSocket::OUTGOING_BUFFER_SIZE - fullness);
  if (result == 0) return MBEDTLS_ERR_SSL_WANT_WRITE;
  memcpy(socket->outgoing_buffer() + fullness, buf, result);
  fullness += result;
  socket->set_outgoing_fullness(fullness);
  return result;
}

static int toit_tls_recv(void* ctx, unsigned char * buf, size_t len) {
  if (len == 0) return 0;
  auto socket = unvoid_cast<MbedTlsSocket*>(ctx);

  int from = socket->from();
  size_t result = Utils::min(socket->incoming_length() - from, len);
  if (result == 0) {
    return MBEDTLS_ERR_SSL_WANT_READ;
  }
  memcpy(buf, socket->incoming_packet() + from, result);
  from += result;
  socket->set_from(from);
  return result;
}

PRIMITIVE(init_socket) {
  ARGS(BaseMbedTlsSocket, socket, cstring, transport_id, bool, skip_certificate_validation);
  USE(transport_id);
  if (skip_certificate_validation) {
    socket->disable_certificate_validation();
  } else {
    socket->apply_certs(process);
  }
  if (!socket->init()) FAIL(MALLOC_FAILED);
  return process->null_object();
}

PRIMITIVE(error) {
  ARGS(MbedTlsSocket, socket, int, error);
  return tls_error(socket, process, -error);
}

bool MbedTlsSocket::init() {
  if (int ret = mbedtls_ssl_setup(&ssl, &conf_)) {
    if (is_tls_malloc_failure(ret)) return false;
    FATAL("mbedtls_ssl_setup returned %x", ret);
  }

  mbedtls_ssl_set_bio(&ssl, this, toit_tls_send, toit_tls_recv, null);
  mbedtls_ssl_conf_verify(&conf_, toit_tls_verify, this);

  return true;
}

#if MBEDTLS_VERSION_MAJOR >= 3 && MBEDTLS_VERSION_MINOR >= 5
#define GET_KEY_BITLEN(info) (mbedtls_cipher_info_get_key_bitlen(info))
#define GET_IV_SIZE(info) (mbedtls_cipher_info_get_iv_size(info))
#else
#define GET_KEY_BITLEN(info) (info->key_bitlen)
#define GET_IV_SIZE(info) (info->iv_size)
#endif

static bool known_cipher_info(const mbedtls_cipher_info_t* info, size_t key_bitlen, int iv_len) {
  if (info->mode == MBEDTLS_MODE_GCM) {
    if (info->type != MBEDTLS_CIPHER_AES_128_GCM && info->type != MBEDTLS_CIPHER_AES_256_GCM) return false;
    if (key_bitlen != 128 && key_bitlen != 192 && key_bitlen != 256) return false;
    if (info->block_size != 16) return false;
  } else if (info->mode == MBEDTLS_MODE_CHACHAPOLY) {
    if (info->type != MBEDTLS_CIPHER_CHACHA20_POLY1305 && info->type != MBEDTLS_CIPHER_CHACHA20_POLY1305) return false;
    if (key_bitlen != 256) return false;
    if (info->block_size != 1) return false;
  } else {
    return false;
  }
  if (GET_KEY_BITLEN(info) != key_bitlen) return false;
  if (iv_len != 12) return false;
  if (GET_IV_SIZE(info) != 12) return false;
  if ((info->flags & ~MBEDTLS_CIPHER_VARIABLE_IV_LEN) != 0) return false;
  return true;
}

static bool known_transform(mbedtls_ssl_transform* transform, size_t iv_len) {
  if (transform->taglen != 16) return false;
  if (transform->ivlen != iv_len) return false;
  return true;
}

PRIMITIVE(get_internals) {
  ARGS(BaseMbedTlsSocket, socket);
  size_t iv_len = socket->ssl.transform_out->ivlen;
  // mbedtls_cipher_context_t from include/mbedtls/cipher.h.
  if (socket->ssl.transform_out == null || socket->ssl.transform_in == null) {
    return Smi::from(42);  // Not ready yet.  This should not happen - it will throw in Toit.
  }
  mbedtls_cipher_context_t* out_cipher_ctx = &socket->ssl.transform_out->cipher_ctx_enc;
  mbedtls_cipher_context_t* in_cipher_ctx = &socket->ssl.transform_in->cipher_ctx_dec;
  size_t key_bitlen = out_cipher_ctx->key_bitlen;
  // mbedtls_cipher_info_t from include/mbedtls/cipher.h.
  const mbedtls_cipher_info_t* out_info = out_cipher_ctx->cipher_info;
  const mbedtls_cipher_info_t* in_info = in_cipher_ctx->cipher_info;

  // Check the connection for parameters we can cope with.
  if (out_info->mode != in_info->mode) return process->null_object();
  if (!known_cipher_info(out_info, key_bitlen, iv_len)) return process->null_object();
  if (!known_cipher_info(in_info, key_bitlen, iv_len)) return process->null_object();
  if (!known_transform(socket->ssl.transform_out, iv_len)) return process->null_object();
  if (!known_transform(socket->ssl.transform_in, iv_len)) return process->null_object();
  if (in_cipher_ctx->key_bitlen != static_cast<int>(key_bitlen)) return process->null_object();
  if (out_cipher_ctx->key_bitlen != static_cast<int>(key_bitlen)) return process->null_object();

  size_t key_len = key_bitlen >> 3;

  ByteArray* encode_iv = process->allocate_byte_array(iv_len);
  ByteArray* decode_iv = process->allocate_byte_array(iv_len);
  ByteArray* encode_key = process->allocate_byte_array(key_len);
  ByteArray* decode_key = process->allocate_byte_array(key_len);
  ByteArray* session_id = process->allocate_byte_array(socket->ssl.session->id_len);
  ByteArray* session_ticket = process->allocate_byte_array(socket->ssl.session->ticket_len);
  ByteArray* master_secret = process->allocate_byte_array(48);
  Array* result = process->object_heap()->allocate_array(9, Smi::zero());
  if (!encode_iv || !decode_iv || !encode_key || !decode_key || !result || !session_id || !session_ticket || !master_secret) FAIL(ALLOCATION_FAILED);
  memcpy(ByteArray::Bytes(encode_iv).address(), socket->ssl.transform_out->iv_enc, iv_len);
  memcpy(ByteArray::Bytes(decode_iv).address(), socket->ssl.transform_in->iv_dec, iv_len);
  memcpy(ByteArray::Bytes(session_id).address(), socket->ssl.session->id, socket->ssl.session->id_len);
  memcpy(ByteArray::Bytes(session_ticket).address(), socket->ssl.session->ticket, socket->ssl.session->ticket_len);
  memcpy(ByteArray::Bytes(master_secret).address(), socket->ssl.session->master, 48);
  if (out_info->mode == MBEDTLS_MODE_GCM) {
    mbedtls_gcm_context* out_gcm_context = reinterpret_cast<mbedtls_gcm_context*>(out_cipher_ctx->cipher_ctx);
    mbedtls_gcm_context* in_gcm_context = reinterpret_cast<mbedtls_gcm_context*>(in_cipher_ctx->cipher_ctx);
#if SOC_AES_SUPPORT_GCM
    mbedtls_aes_context* out_aes_context = &out_gcm_context->aes_ctx;
    mbedtls_aes_context* in_aes_context = &in_gcm_context->aes_ctx;
#elif defined(MBEDTLS_GCM_ALT)
    esp_aes_context* out_aes_context = &out_gcm_context->aes_ctx;
    esp_aes_context* in_aes_context = &in_gcm_context->aes_ctx;
#else
    mbedtls_cipher_context_t* out_cipher_context = &out_gcm_context->cipher_ctx;
    mbedtls_cipher_context_t* in_cipher_context = &in_gcm_context->cipher_ctx;
    mbedtls_aes_context* out_aes_context = reinterpret_cast<mbedtls_aes_context*>(out_cipher_context->cipher_ctx);
    mbedtls_aes_context* in_aes_context = reinterpret_cast<mbedtls_aes_context*>(in_cipher_context->cipher_ctx);
#endif
    if (out_gcm_context->mode != MBEDTLS_GCM_ENCRYPT ||
        in_gcm_context->mode != MBEDTLS_GCM_DECRYPT) {
      return process->null_object();
    }
#if MBEDTLS_VERSION_MAJOR >= 3
#ifdef MBEDTLS_GCM_ALT
    memcpy(ByteArray::Bytes(encode_key).address(), out_aes_context->key, key_len);
    memcpy(ByteArray::Bytes(decode_key).address(), in_aes_context->key, key_len);
#else
    memcpy(ByteArray::Bytes(encode_key).address(), out_aes_context->buf + out_aes_context->rk_offset, key_len);
    memcpy(ByteArray::Bytes(decode_key).address(), in_aes_context->buf + in_aes_context->rk_offset, key_len);
#endif
#elif defined(TOIT_FREERTOS)
    if (out_aes_context->key_bytes != key_len ||
        in_aes_context->key_bytes != key_len) {
      return process->null_object();
    }
    memcpy(ByteArray::Bytes(encode_key).address(), out_aes_context->key, key_len);
    memcpy(ByteArray::Bytes(decode_key).address(), in_aes_context->key, key_len);
#else
    memcpy(ByteArray::Bytes(encode_key).address(), out_aes_context->rk, key_len);
    memcpy(ByteArray::Bytes(decode_key).address(), in_aes_context->rk, key_len);
#endif
    result->at_put(0, Smi::from(ALGORITHM_AES_GCM));
  } else {
    ASSERT(out_info->mode == MBEDTLS_MODE_CHACHAPOLY);
    mbedtls_chacha20_context* out_ccp_context =
        &reinterpret_cast<mbedtls_chachapoly_context*>(out_cipher_ctx->cipher_ctx)->chacha20_ctx;
    mbedtls_chacha20_context* in_ccp_context =
        &reinterpret_cast<mbedtls_chachapoly_context*>(in_cipher_ctx->cipher_ctx)->chacha20_ctx;
    memcpy(ByteArray::Bytes(encode_key).address(), reinterpret_cast<const uint8*>(&out_ccp_context->state[4]), key_len);
    memcpy(ByteArray::Bytes(decode_key).address(), reinterpret_cast<const uint8*>(&in_ccp_context->state[4]), key_len);
    result->at_put(0, Smi::from(ALGORITHM_CHACHA20_POLY1305));
  }
  result->at_put(1, encode_key);
  result->at_put(2, decode_key);
  result->at_put(3, encode_iv);
  result->at_put(4, decode_iv);
  result->at_put(5, session_id);
  result->at_put(6, session_ticket);
  result->at_put(7, master_secret);
  result->at_put(8, Smi::from(socket->ssl.session->ciphersuite));

  return result;
}

PRIMITIVE(get_random) {
  ARGS(MutableBlob, destination);
  EntropyMixer::instance()->get_entropy(destination.address(), destination.length());
  return process->null_object();
}

#ifdef TOIT_FREERTOS
// On small platforms we disallow concurrent handshakes
// to avoid running into memory issues.
static const int HANDSHAKE_CONCURRENCY = 1;
#else
static const int HANDSHAKE_CONCURRENCY = 16;
#endif

class TlsHandshakeToken;
typedef DoubleLinkedList<TlsHandshakeToken> TlsHandshakeTokenList;

// The handshake tokens are used to limit the amount of
// concurrent TLS handshakes we do. At any time, there
// can be at most HANDSHAKE_CONCURRENCY tokens with
// a non-zero state. All zero state tokens are chained
// together in a waiters list and get a non-zero state
// one at a time as other tokens are released.
class TlsHandshakeToken : public Resource, public TlsHandshakeTokenList::Element {
 public:
  TAG(TlsHandshakeToken);
  explicit TlsHandshakeToken(MbedTlsResourceGroup* group)
      : Resource(group) {
    TlsHandshakeToken* token = acquire();
    if (token) {
      ASSERT(token == this);
      set_state(1);
    }
  }

  ~TlsHandshakeToken() {
    TlsHandshakeToken* token = release();
    if (token) {
      ASSERT(token != this);
      EventSource* source = token->resource_group()->event_source();
      source->set_state(token, 1);
    }
  }

 private:
  static int count;
  static TlsHandshakeTokenList waiters;

  TlsHandshakeToken* acquire() {
    Locker locker(OS::tls_mutex());
    if (count > 0) {
      count--;
      return this;
    } else {
      waiters.append(this);
      return null;
    }
  }

  TlsHandshakeToken* release() {
    Locker locker(OS::tls_mutex());
    if (waiters.is_linked(this)) {
      waiters.unlink(this);
      return null;
    } else if (waiters.is_empty()) {
      count++;
      return null;
    } else {
      return waiters.remove_first();
    }
  }
};

int TlsHandshakeToken::count = HANDSHAKE_CONCURRENCY;
TlsHandshakeTokenList TlsHandshakeToken::waiters;

PRIMITIVE(token_acquire) {
  ARGS(MbedTlsResourceGroup, group);

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) FAIL(ALLOCATION_FAILED);

  TlsHandshakeToken* token = _new TlsHandshakeToken(group);
  if (!token) FAIL(MALLOC_FAILED);

  proxy->set_external_address(token);
  return proxy;
}

PRIMITIVE(token_release) {
  ARGS(ByteArray, proxy);

  TlsHandshakeToken* token = proxy->as_external<TlsHandshakeToken>();
  token->resource_group()->unregister_resource(token);
  proxy->clear_external_address();

  return process->null_object();
}

} // namespace toit

#endif // !defined(TOIT_FREERTOS) || CONFIG_TOIT_CRYPTO
