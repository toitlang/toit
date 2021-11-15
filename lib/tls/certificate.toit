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
