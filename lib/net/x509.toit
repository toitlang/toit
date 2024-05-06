// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

x509-module_ := x509-init_

class Certificate:
  res_ ::= ?

  // Load a certificate from a PEM or DER encoded string or byte array.
  constructor.parse input:
    res := x509-parse_ x509-module_ input
    return Certificate.resource_ res

  constructor.resource_ .res_:
    add-finalizer this::
      remove-finalizer this
      x509-close this.res_

  // Get the Common Name (CN) of the certificate.
  common-name -> string:
    return x509-get-common-name_ res_

x509-init_:
  #primitive.x509.init

x509-parse_ module input:
  #primitive.x509.parse

x509-get-common-name_ cert:
  #primitive.x509.get-common-name

x509-close cert:
  #primitive.x509.close
