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
#include <mbedtls/error.h>
#include <mbedtls/pem.h>
#include <mbedtls/gcm.h>
#include <mbedtls/platform.h>
#include <mbedtls/ssl_internal.h>

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

int BaseMbedTlsSocket::add_certificate(X509Certificate* cert, const uint8_t* private_key, size_t private_key_length, const uint8_t* password, int password_length) {
  uninit_certs();  // Remove any old cert on the config.

  private_key_ = _new mbedtls_pk_context;
  if (!private_key_) return MBEDTLS_ERR_PK_ALLOC_FAILED;
  mbedtls_pk_init(private_key_);
  int ret = mbedtls_pk_parse_key(private_key_, private_key, private_key_length, password, password_length);
  if (ret < 0) {
    delete private_key_;
    private_key_ = null;
    return ret;
  }

  ret = mbedtls_ssl_conf_own_cert(&conf_, cert->cert(), private_key_);
  return ret;
}

int BaseMbedTlsSocket::add_root_certificate(X509Certificate* cert) {
  // Copy to a per-certificate chain.
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

void BaseMbedTlsSocket::apply_certs() {
  if (root_certs_) {
    mbedtls_ssl_conf_ca_chain(&conf_, root_certs_, null);
  }
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
  auto group = unvoid_cast<MbedTlsResourceGroup*>(ctx);
  return group->verify_callback(cert, certificate_depth, flags);
}

int MbedTlsResourceGroup::verify_callback(mbedtls_x509_crt* crt, int certificate_depth, uint32_t* flags) {
  if (*flags != 0) {
    if ((*flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED) != 0) {
      // This is the error when the cert relies on a root that we have not
      // trusted/added.
      const int BUFFER_SIZE = 200;
      char buffer[BUFFER_SIZE];
      int ret = mbedtls_x509_dn_gets(buffer, BUFFER_SIZE, &crt->issuer);
      if (ret > 0 && ret < BUFFER_SIZE) {
        // If we are unlucky and the malloc fails, then the error message will
        // be less informative.
        char* issuer = unvoid_cast<char*>(malloc(ret + 1));
        if (issuer) {
          memcpy(issuer, buffer, ret);
          issuer[ret] = '\0';
          if (error_issuer_) free(error_issuer_);
          error_issuer_ = issuer;
        }
      }
    }
    error_flags_ = *flags;
    error_depth_ = certificate_depth;
  }
  return 0; // Keep going.
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
  mbedtls_ssl_conf_verify(conf, toit_tls_verify, this);
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
  , private_key_(null) {
  mbedtls_ssl_init(&ssl);
  group->init_conf(&conf_);
}

BaseMbedTlsSocket::~BaseMbedTlsSocket() {
  mbedtls_ssl_free(&ssl);
  uninit_certs();
  mbedtls_ssl_config_free(&conf_);
  for (mbedtls_x509_crt* c = root_certs_; c != null;) {
    mbedtls_x509_crt* n = c->next;
    delete c;
    c = n;
  }
}

MbedTlsSocket::MbedTlsSocket(MbedTlsResourceGroup* group)
  : BaseMbedTlsSocket(group)
  , outgoing_packet_(group->process()->program()->null_object())
  , outgoing_fullness_(0)
  , incoming_packet_(group->process()->program()->null_object())
  , incoming_from_(0) {
  ObjectHeap* heap = group->process()->object_heap();
  heap->add_external_root(&outgoing_packet_);
  heap->add_external_root(&incoming_packet_);
}

MbedTlsSocket::~MbedTlsSocket() {
  ObjectHeap* heap = resource_group()->process()->object_heap();
  heap->remove_external_root(&outgoing_packet_);
  heap->remove_external_root(&incoming_packet_);
}

MODULE_IMPLEMENTATION(tls, MODULE_TLS)

Object* tls_error(MbedTlsResourceGroup* group, Process* process, int err) {
  static const size_t BUFFER_LEN = 400;
  char buffer[BUFFER_LEN];
  if (err == MBEDTLS_ERR_CIPHER_ALLOC_FAILED ||
      err == MBEDTLS_ERR_ECP_ALLOC_FAILED ||
      err == MBEDTLS_ERR_MD_ALLOC_FAILED ||
      err == MBEDTLS_ERR_MPI_ALLOC_FAILED ||
      err == MBEDTLS_ERR_PEM_ALLOC_FAILED ||
      err == MBEDTLS_ERR_PK_ALLOC_FAILED ||
      err == MBEDTLS_ERR_SSL_ALLOC_FAILED ||
      err == MBEDTLS_ERR_X509_ALLOC_FAILED) {
    MALLOC_FAILED;
  }
  if (err == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED &&
      group &&
      group->error_flags() &&
      (group->error_flags() & ~MBEDTLS_X509_BADCERT_NOT_TRUSTED) == 0 &&
      group->error_issuer()) {
    size_t len = snprintf(buffer, BUFFER_LEN - 1, "Site relies on unknown root certificate: '%s'", group->error_issuer());
    if (len > 0 && len < BUFFER_LEN) {
      buffer[len] = '\0';
      if (!Utils::is_valid_utf_8(unsigned_cast(buffer), len)) {
        for (unsigned i = 0; i < len; i++) if (buffer[i] & 0x80) buffer[i] = '.';
      }
      String* str = process->allocate_string(buffer);
      if (str == null) ALLOCATION_FAILED;
      group->clear_error_flags();
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
  if (group && group->error_flags() != 0 && used < BUFFER_LEN - 30) {
    buffer[used] = ':';
    buffer[used + 1] = ' ';
    buffer[used + 2] = '\0';
    used += 2;
    sprintf(buffer + used, "Cert depth %d:\n", group->error_depth());
    used = strlen(buffer);
    mbedtls_x509_crt_verify_info(buffer + used, BUFFER_LEN - used, " * ", group->error_flags());
    used = strlen(buffer);
    if (used && buffer[used - 1] == '\n') {
      used--;
      buffer[used] = '\0';
    }
  }
  buffer[BUFFER_LEN - 1] = '\0';
  String* str = process->allocate_string(buffer);
  if (str == null) ALLOCATION_FAILED;
  if (group) group->clear_error_flags();
  return Primitive::mark_as_error(str);
}

PRIMITIVE(get_outgoing_fullness) {
  ARGS(MbedTlsSocket, socket);
  return Smi::from(socket->outgoing_fullness());
}

PRIMITIVE(set_outgoing) {
  ARGS(MbedTlsSocket, socket, Object, outgoing, int, fullness);
  Object* null_object = process->program()->null_object();
  if (outgoing == null_object) {
    if (fullness != 0) INVALID_ARGUMENT;
  } else if (is_byte_array(outgoing)) {
    ByteArray::Bytes data_bytes(ByteArray::cast(outgoing));
    if (fullness < 0 || fullness >= data_bytes.length()) INVALID_ARGUMENT;
  } else {
    INVALID_ARGUMENT;
  }
  socket->set_outgoing(outgoing, fullness);
  return null_object;
}

PRIMITIVE(get_incoming_from) {
  ARGS(MbedTlsSocket, socket);
  return Smi::from(socket->from());
}

PRIMITIVE(set_incoming) {
  ARGS(MbedTlsSocket, socket, Object, incoming, int, from);
  Blob blob;
  if (!incoming->byte_content(process->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) WRONG_TYPE;
  if (from < 0 || from > blob.length()) INVALID_ARGUMENT;
  socket->set_incoming(incoming, from);
  return process->program()->null_object();
}

PRIMITIVE(init) {
  ARGS(bool, server)

  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  // Mark usage. When the group is unregistered, the usage is automatically
  // decremented, but if group allocation fails, we manually call unuse().
  TlsEventSource* tls = TlsEventSource::instance();
  if (!tls->use()) MALLOC_FAILED;

  auto mode = server ? MbedTlsResourceGroup::TLS_SERVER : MbedTlsResourceGroup::TLS_CLIENT;
  MbedTlsResourceGroup* group = _new MbedTlsResourceGroup(process, tls, mode);
  if (!group) {
    tls->unuse();
    MALLOC_FAILED;
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
  return process->program()->null_object();
}

Object* MbedTlsResourceGroup::tls_socket_create(Process* process, const char* hostname) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  MbedTlsSocket* socket = _new MbedTlsSocket(this);

  if (socket == null) MALLOC_FAILED;
  proxy->set_external_address(socket);

  mbedtls_ssl_set_hostname(&socket->ssl, hostname);
  register_resource(socket);
  return proxy;
}

PRIMITIVE(create) {
  ARGS(MbedTlsResourceGroup, resource_group, cstring, hostname);

  return resource_group->tls_socket_create(process, hostname);
}

bool ensure_handshake_memory() {
  // TLS handshake allocates with a high water mark of 12-13k.  We don't
  // currently have a way to reserve that memory, but we can at least ensure
  // that that amount of memory can be allocated before we start, and trigger
  // GC if it can't.  Since the system is multithreaded and the allocator is
  // subject to fragmentation this doesn't actually guarantee that the
  // handshake will succeed, but increases the probability.  If an allocation
  // fails during a handshake step then the TLS connection fails and has to be
  // restarted from scratch.  This is annoying, but most code will already be
  // able to restart TLS connections since they can fail because of transient
  // network issues.
  HeapTagScope scope(ITERATE_CUSTOM_TAGS + BIGNUM_MALLOC_TAG);
  const int BLOCK_SIZE = 1900;
  const int BLOCK_COUNT = 8;
  void* blocks[BLOCK_COUNT] = { 0 };
  bool success = true;
  for (int i = 0; i < BLOCK_COUNT; i++) {
    blocks[i] = malloc(BLOCK_SIZE);
    success = success && blocks[i];
  }
  dont_optimize_away_these_allocations(blocks);
  for (int i = 0; i < BLOCK_COUNT; i++) free(blocks[i]);
  return success;
}

PRIMITIVE(handshake) {
  ARGS(MbedTlsSocket, socket);
  if (!ensure_handshake_memory()) MALLOC_FAILED;
  TlsEventSource::instance()->handshake(socket);
  return process->program()->null_object();
}

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
  if (array == null) ALLOCATION_FAILED;
  int read = mbedtls_ssl_read(&socket->ssl, ByteArray::Bytes(array).address(), size);
  if (read == 0 || read == MBEDTLS_ERR_SSL_CONN_EOF || read == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
    return process->program()->null_object();
  } else if (read == MBEDTLS_ERR_SSL_WANT_READ) {
    return Smi::from(TLS_WANT_READ);
  } else if (read < 0) {
    return tls_error(null, process, read);
  }

  array->resize_external(process, read);
  return array;
}

PRIMITIVE(write) {
  ARGS(MbedTlsSocket, socket, Blob, data, int, from, int, to)

  if (from < 0 || from > to || to > data.length()) OUT_OF_RANGE;

  int wrote = mbedtls_ssl_write(&socket->ssl, data.address() + from, to - from);
  if (wrote < 0) {
    if (wrote == MBEDTLS_ERR_SSL_WANT_WRITE) {
      wrote = 0;
    } else {
      return tls_error(null, process, wrote);
    }
  }

  return Smi::from(wrote);
}

PRIMITIVE(close_write) {
  ARGS(MbedTlsSocket, socket);

  mbedtls_ssl_close_notify(&socket->ssl);

  return process->program()->null_object();
}

PRIMITIVE(close) {
  ARGS(MbedTlsSocket, socket);
  socket->resource_group()->unregister_resource(socket);

  socket_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(add_root_certificate) {
  ARGS(BaseMbedTlsSocket, socket, X509Certificate, cert);
  if (cert->cert()->next) INVALID_ARGUMENT;  // You can only append a single cert, not a chain of certs.
  int ret = socket->add_root_certificate(cert);
  if (ret != 0) return tls_error(null, process, ret);
  return process->program()->null_object();
}

PRIMITIVE(add_certificate) {
  ARGS(BaseMbedTlsSocket, socket, X509Certificate, certificate, blob_or_string_with_terminating_null, private_key, blob_or_string_with_terminating_null, password);

  int ret = socket->add_certificate(certificate, private_key, private_key_length, password, password_length);
  if (ret != 0) return tls_error(null, process, ret);
  return process->program()->null_object();
}

static int toit_tls_send(void* ctx, const unsigned char* buf, size_t len) {
  auto socket = unvoid_cast<MbedTlsSocket*>(ctx);
  if (!is_byte_array(socket->outgoing_packet())) {
    return MBEDTLS_ERR_SSL_WANT_WRITE;
  }
  ByteArray::Bytes bytes(static_cast<ByteArray*>(socket->outgoing_packet()));
  int fullness = socket->outgoing_fullness();
  size_t result = Utils::min(static_cast<size_t>(bytes.length() - fullness), len);
  if (result == 0) return MBEDTLS_ERR_SSL_WANT_WRITE;
  memcpy(bytes.address() + fullness, buf, result);
  fullness += result;
  socket->set_outgoing_fullness(fullness);
  return result;
}

static int toit_tls_recv(void* ctx, unsigned char * buf, size_t len) {
  if (len == 0) return 0;
  auto socket = unvoid_cast<MbedTlsSocket*>(ctx);
  Blob blob;
  if (!socket->incoming_packet()->byte_content(socket->resource_group()->process()->program(), &blob, STRINGS_OR_BYTE_ARRAYS)) {
    return MBEDTLS_ERR_SSL_WANT_READ;
  }

  int from = socket->from();
  size_t result = Utils::min(static_cast<size_t>(blob.length() - from), len);
  if (result == 0) {
    return MBEDTLS_ERR_SSL_WANT_READ;
  }
  memcpy(buf, blob.address() + from, result);
  from += result;
  socket->set_from(from);
  return result;
}

PRIMITIVE(init_socket) {
  ARGS(BaseMbedTlsSocket, socket, cstring, transport_id);
  socket->apply_certs();
  if (!socket->init(transport_id)) MALLOC_FAILED;
  return process->program()->null_object();
}

PRIMITIVE(error) {
  ARGS(MbedTlsResourceGroup, group, int, error);
  return tls_error(group, process, -error);
}

bool MbedTlsSocket::init(const char*) {
  if (int ret = mbedtls_ssl_setup(&ssl, &conf_)) {
    if (ret == MBEDTLS_ERR_SSL_ALLOC_FAILED) return false;
    FATAL("mbedtls_ssl_setup returned %d (not %d)", ret, MBEDTLS_ERR_SSL_ALLOC_FAILED);
  }

  mbedtls_ssl_set_bio(&ssl, this, toit_tls_send, toit_tls_recv, null);

  return true;
}

// Takes a deep copy of the SSL session provided by MbedTLS.
int SslSession::serialize(mbedtls_ssl_session* session, Blob* blob_return) {
  size_t struct_size = sizeof(*session);
  size_t cert_size = 0;
  if (session->peer_cert != null) {
    cert_size = session->peer_cert->raw.len;
    if (cert_size > 0xffff) return CORRUPT;
  }
  size_t ticket_size = 0;
  if (session->ticket_len != 0) {
    ticket_size  = session->ticket_len;
    if (ticket_size > 0xffff) return CORRUPT;
  }
  size_t size = 6 + struct_size + cert_size + ticket_size;
  uint8* data = unvoid_cast<uint8_t*>(malloc(size));
  if (data == null) return OUT_OF_MEMORY;

  SslSession ssl_session(data);
  int ret = ssl_session.serialize(session, struct_size, cert_size, ticket_size);
  if (ret != OK) {
    free(data);
    return ret;
  }
  *blob_return = Blob(data, size);
  return OK;
}

int SslSession::serialize(mbedtls_ssl_session* session, size_t struct_size, size_t cert_size, size_t ticket_size) {
  memcpy(struct_address(), reinterpret_cast<const uint8*>(session), struct_size);
  set_struct_size(struct_size);
  if (cert_size)
    memcpy(cert_address(), reinterpret_cast<const uint8*>(session->peer_cert->raw.p), cert_size);
  set_cert_size(cert_size);
  memcpy(ticket_address(), reinterpret_cast<const uint8*>(session->ticket), ticket_size);
  set_ticket_size(ticket_size);

  return OK;
}

// Creates a "fake" mbedtls_ssl_session that can be used as input
// to ssl_session_copy in ssl_tls.c.
int SslSession::deserialize(Blob serialized, mbedtls_ssl_session* returned_value) {
  SslSession session(const_cast<uint8*>(serialized.address()));
  int ret = session.deserialize(serialized.length(), returned_value);
  return ret;
}

int SslSession::deserialize(word serialized_length, mbedtls_ssl_session* returned_value) {
  mbedtls_ssl_session_init(returned_value);

  // It's important for overflow that this is a larger type than the individual size fields.
  word expected_size = 6;
  expected_size += struct_size() + cert_size() + ticket_size();
  if (expected_size != serialized_length ||
      struct_size() != sizeof(mbedtls_ssl_session)) {
    return CORRUPT;
  }
  // Create struct.
  mbedtls_ssl_session* ssl_session = returned_value;
  memcpy(ssl_session, struct_address(), struct_size());

  // Create ticket.
  ssl_session->ticket = ticket_address();
  ssl_session->ticket_len = ticket_size();

  // Create peer cert.
  if (cert_size() != 0) {
    // Freed in free_session.
    ssl_session->peer_cert = _new mbedtls_x509_crt;
    if (ssl_session->peer_cert == null) {
      ssl_session->ticket = null;
      return OUT_OF_MEMORY;
    }
    mbedtls_x509_crt_init(ssl_session->peer_cert);

    // These are the only parts used by ssl_session_copy.
    ssl_session->peer_cert->raw.p = cert_address();
    ssl_session->peer_cert->raw.len = cert_size();
  }

  return OK;
}

void SslSession::free_session(mbedtls_ssl_session* session) {
  delete session->peer_cert;
}


PRIMITIVE(get_session) {
  ARGS(BaseMbedTlsSocket, socket);

  ByteArray* proxy = process->object_heap()->allocate_proxy(true);
  if (proxy == null) ALLOCATION_FAILED;

  mbedtls_ssl_session session;
  mbedtls_ssl_session_init(&session);

  int ret = mbedtls_ssl_get_session(&socket->ssl, &session);

  if (ret != 0) {
    return tls_error(null, process, ret);
  }

  Blob result;
  ret = SslSession::serialize(&session, &result);

  mbedtls_ssl_session_free(&session);

  if (ret != SslSession::OK) {
    if (ret == SslSession::OUT_OF_MEMORY) MALLOC_FAILED;
    if (ret == SslSession::CORRUPT) INVALID_ARGUMENT;
    return tls_error(null, process, ret);
  }

  proxy->set_external_address(result.length(), const_cast<uint8*>(result.address()));
  process->object_heap()->register_external_allocation(result.length());
  return proxy;
}

PRIMITIVE(set_session) {
  // PRIVILEGED; TODO: When we are done testing this should probably be privileged.
  ARGS(BaseMbedTlsSocket, socket, Blob, serialized);

  mbedtls_ssl_session ssl_session;
  mbedtls_ssl_session_init(&ssl_session);
  int result = SslSession::deserialize(serialized, &ssl_session);

  if (result != SslSession::OK) {
    if (result == SslSession::OUT_OF_MEMORY) MALLOC_FAILED;
    if (result == SslSession::CORRUPT) INVALID_ARGUMENT;
    return tls_error(null, process, result);
  }

  // Set the session and remember to always free the fake session
  // created by deserialize.
  result = mbedtls_ssl_set_session(&socket->ssl, &ssl_session);
  SslSession::free_session(&ssl_session);

  if (result != 0) {
    return tls_error(null, process, result);
  }
  return process->program()->null_object();
}

PRIMITIVE(get_internals) {
  ARGS(BaseMbedTLSSocket, socket);
  size_t iv_len = socket->ssl.transform_out->ivlen;
  // mbedtls_cipher_context_t from include/mbedtls/cipher.h.
  mbedtls_cipher_context_t* out_cipher_ctx = &socket->ssl.transform_out->cipher_ctx_enc;
  mbedtls_cipher_context_t* in_cipher_ctx = &socket->ssl.transform_in->cipher_ctx_dec;
  size_t key_bitlen = out_cipher_ctx->key_bitlen;
  // mbedtls_cipher_info_t from include/mbedtls/cipher.h.
  const mbedtls_cipher_info_t* out_info = out_cipher_ctx->cipher_info;
  const mbedtls_cipher_info_t* in_info = in_cipher_ctx->cipher_info;

  // Sanity check the connection for parameters we can cope with.
  if (   (out_info->type != MBEDTLS_CIPHER_AES_128_GCM &&
             out_info->type != MBEDTLS_CIPHER_AES_256_GCM)
      || (in_info->type != MBEDTLS_CIPHER_AES_128_GCM &&
             in_info->type != MBEDTLS_CIPHER_AES_256_GCM)
      || out_info->mode != MBEDTLS_MODE_GCM
      || in_info->mode != MBEDTLS_MODE_GCM
      || out_info->key_bitlen != key_bitlen
      || in_info->key_bitlen != key_bitlen
      || iv_len != 12
      || out_info->iv_size != 12
      || in_info->iv_size != 12
      || out_info->flags != 0
      || in_info->flags != 0
      || out_info->block_size != 16
      || in_info->block_size != 16
      || socket->ssl.transform_in->taglen != 16
      || socket->ssl.transform_out->taglen != 16
      || socket->ssl.transform_in->ivlen != iv_len
      || in_cipher_ctx->key_bitlen != static_cast<int>(key_bitlen)) {
    return process->program()->null_object();
  }

  ByteArray* encode_iv = process->allocate_byte_array(iv_len);
  ByteArray* decode_iv = process->allocate_byte_array(iv_len);
  ByteArray* encode_key = process->allocate_byte_array(key_bitlen >> 3);
  ByteArray* decode_key = process->allocate_byte_array(key_bitlen >> 3);
  Array* result = process->object_heap()->allocate_array(4, Smi::zero());
  if (!encode_iv || !decode_iv || !encode_key || !decode_key || !result) ALLOCATION_FAILED;
  memcpy(ByteArray::Bytes(encode_iv).address(), socket->ssl.transform_out->iv_enc, iv_len);
  memcpy(ByteArray::Bytes(decode_iv).address(), socket->ssl.transform_in->iv_dec, iv_len);
  mbedtls_gcm_context* out_gcm_context = reinterpret_cast<mbedtls_gcm_context*>(out_cipher_ctx->cipher_ctx);
  mbedtls_gcm_context* in_gcm_context = reinterpret_cast<mbedtls_gcm_context*>(in_cipher_ctx->cipher_ctx);
  if (  out_gcm_context->mode != MBEDTLS_GCM_ENCRYPT
      || in_gcm_context->mode != MBEDTLS_GCM_DECRYPT) {
    return process->program()->null_object();
  }
  //memcpy(ByteArray::Bytes(encode_key).address(), out_cipher_ctx->cipher_ctx, key_len);
  //memcpy(ByteArray::Bytes(decode_key).address(), in_cipher_ctx->cipher_ctx, key_len);
  result->at_put(0, encode_iv);
  result->at_put(1, decode_iv);
  result->at_put(2, encode_key);
  result->at_put(3, decode_key);

  return result;
}

} // namespace toit
#endif // !defined(TOIT_FREERTOS) || CONFIG_TOIT_CRYPTO
