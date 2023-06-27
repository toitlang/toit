// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net.x509 as x509

/**
TLS Certificate used as identity in a TLS session.

It's composed of a x509 certificate and the associated private key.
*/
class Certificate:
  certificate/x509.Certificate
  /** The private key can be either string or ByteArray. */
  private_key/any
  password/string

  /**
  Creates a new TLS Certificate from a x509 certificate and a private key.

  An optional password can be given, to unlock the private key if needed.
  */
  constructor .certificate .private_key --.password="":

/**
Add a trusted root certificate that can be used for all TLS connections.

This function is an alternative to adding root certificates to individual TLS
  sockets, or using the --root_certificates argument on the HTTP client.
  If you add root certificates to a specific connection then these global
  certificates are not consulted for that connection, not even as a fallback.

The trusted roots added with this function have a "subject" field that is used
  to match with the "issuer" field that the server provides. Only matching
  roots are tried when attempting to verify a server certificate. The
  "AuthorityKeyIdentifier" and "SubjectKeyIdentifer" extensions are not
  supported.

Certificates, the $cert argument, are added here in unparsed form, ie either in
  PEM (ASCII) format or in DER format. Usually you would use a byte array
  constant in DER format, which will stay in flash on embedded platforms, using
  very little memory until it is needed to complete a TLS handshake. Trying to
  add an instance of $Certificate or $x509.Certificate with this function will
  throw an error.

Returns the hash of the added certificate, which can be used to add it more
  efficiently, without parsing the certificate at startup time.
*/
add_global_root_certificate cert hash/int?=null -> int:
  #primitive.tls.add_global_root_certificate
