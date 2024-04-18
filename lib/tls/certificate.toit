// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net.x509 as x509
import tls

/**
TLS Certificate used as identity in a TLS session.

It's composed of a x509 certificate and the associated private key.
*/
class Certificate:
  certificate/x509.Certificate
  /** The private key can be either string or ByteArray. */
  private-key/any
  password/string

  /**
  Creates a new TLS Certificate from a x509 certificate and a private key.

  An optional password can be given, to unlock the private key if needed.
  */
  constructor .certificate .private-key --.password="":

/**
Trusted Root TLS Certificate used to verify a server's identity.

It is composed of a x509 certificate and a fingerprint.
*/
class RootCertificate:
  fingerprint/int?
  parsed_/x509.Certificate? := null
  name/string? := null
  raw ::= ?

  stringify -> string:
    return name or "Root certificate w/ fingerprint $fingerprint"

  /**
  Constructs a RootCertificate from a binary DER-endoded certificate
    or an ASCII PEM-encoded certificate.

  The $raw certificate is in unparsed form, either in PEM (ASCII) format or
    in DER format. Usually you would use a byte array constant in DER format,
    which will stay in flash on embedded platforms, using very little memory.
    More memory is used when it is added to a TLS socket.  If it is installed
    in the process with $install then no extra memory is used until it is
    needed to complete a TLS handshake.
  */
  constructor --.name=null --.fingerprint=null .raw:
    if raw is not ByteArray and raw is not string: throw "WRONG_OBJECT_TYPE"

  /**
  Gets a parsed form suitable for adding to a TLS socket.
  */
  ensure-parsed_ -> x509.Certificate:
    if parsed_ == null:
      parsed_ = x509.Certificate.parse raw
    return parsed_

  /**
  Add a trusted root certificate that can be used for all TLS connections.

  This method is an alternative to adding root certificates to individual TLS
    sockets, or using the --root-certificates argument on the HTTP client.
    If you add root certificates to a specific connection then these global
    certificates are not consulted for that connection, not even as a fallback.

  The trusted roots added with this method have a "subject" field that is used
    to match with the "issuer" field that the server provides. Only matching
    roots are tried when attempting to verify a server certificate. The
    "AuthorityKeyIdentifier" and "SubjectKeyIdentifer" extensions are not
    supported.
  */
  install -> none:
    add-global-root-certificate_ raw fingerprint

/**
Add a trusted root certificate that can be used for all TLS connections.

This function is an alternative to adding root certificates to individual TLS
  sockets, or using the --root-certificates argument on the HTTP client.
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
add-global-root-certificate_ cert hash/int?=null -> int:
  #primitive.tls.add-global-root-certificate

/**
Adds the trusted root certificates that are installed on the system.

This is only supported on Windows.  On other platforms it currently does
  nothing.

This need only be called once, then it is available for all TLS connections.

Like $RootCertificate.install, this function is an alternative to adding
  root certificates to individual TLS sockets.
*/
use-system-trusted-root-certificates -> none:
  #primitive.tls.use-system-trusted-root-certificates
