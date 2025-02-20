// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import .socket
import .certificate
import .session

export *

/**
TLS support.

# Sockets
A secure connection can be established by upgrading a TCP socket to a TLS $Socket.

For connections to a secure server, the $Socket.client constructor is used. It
  takes a TCP socket, the server name, and an optional client certificate. It
  also takes a list of root certificates, but installing root certificates is
  the recommended way to handle root certificates.

Closing the secure socket will automatically close the underlying TCP socket. It
  is thus not necessary to hold a reference to the TCP socket.

Example:
```
import net
import tls

main:
  network := net.open
  socket := network.tcp-connect "example.com" 443
  tls-socket := tls.Socket.client socket --server-name="example.com"
  tls-socket.close
```

# TLS resume
Establishing a TLS connection is expensive (computationally and memory-wise).
  To avoid this cost, a TLS session can be resumed. This is done by saving the
  session state after the handshake is complete, and then reusing it for the
  next connection. Use the $Socket.session-state to get the session state, and
  $Socket.session-state= to set it. If the state is null, then the server doesn't
  support session resumption.

Example:
```
import net
import tls

main:
  network := net.open
  socket := network.tcp-connect "example.com" 443
  tls-socket := tls.Socket.client socket --server-name="example.com"
  session-state := tls-socket.session-state
  tls-socket.close

  if session-state == null:
    print "Server doesn't support session resumption"
    return

  socket := network.tcp-connect "example.com" 443
  tls-socket := tls.Socket.client socket --server-name="example.com"
  tls-socket.session-state = session-state
  tls-socket.close
```

Session-state information is not encrypted and should be treated as sensitive
  information. It should be stored securely and not shared with untrusted parties.
  Access to it allows man-in-the-middle attacks.
  On the ESP32 we believe that the RTC memory is secure enough to store this
  information.

# Certificates
The $RootCertificate class is used to verify a server's identity. It is composed
  of a x509 certificate and a fingerprint.

It is constructed from a binary DER-encoded certificate or an ASCII PEM-encoded
  certificate. The certificate is in unparsed form, either in PEM (ASCII) format
  or in DER format. Usually you would use a byte array constant in DER format,
  which will stay in flash on embedded platforms, using very little memory. More
  memory is used when it is added to a TLS socket.

Root certificates are installed by calling $RootCertificate.install. This makes
  it available to all TLS sockets in the process. The certificate is not parsed
  until it is needed to complete a TLS handshake. This means that no extra memory
  is used until the certificate is needed.

Example:
```
import tls

DER-CERTIFICATE ::= #[
  0x30, 0x82, 0x02, 0x4e, 0x30, 0x82, 0x01, 0xd6, 0x02, 0x09, 0x00, 0x9d
  ...
]

main:
  root-certificate := tls.RootCertificate --name="My Root Certificate" DER-CERTIFICATE
  root-certificate.install
```

Users rarely have to build their own certificate roots, but can simply use the
  ones from the `certificate-roots` package (`github.com/toitware/toit-cert-roots`)
  which contains the certificates that are trusted by Mozilla.

The $Certificate class provides a way to create a TLS certificate from a x509
  certificate and a private key. The private key can be either a string or a
  byte array. An optional password can be given to unlock the private key if
  needed.

The $Certificate class is, for example, used when running a TLS server.

Example:
```
import tls

SERVER-CERTIFICATE ::= x509.Certificate.parse """
--- BEGIN CERTIFICATE ---
...
--- END CERTIFICATE ---
"""

SERVER-KEY ::= """
-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----
"""

main:
  certificate := tls.Certificate SERVER-CERTIFICATE SERVER-KEY

```
*/
