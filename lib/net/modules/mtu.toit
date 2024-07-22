// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// IMPORTANT
// =========
// On the ESP32, the $TOIT-MTU-TCP should match CONFIG_TCP_MSS and CONFIG_LWIP_TCP_MSS
// from the sdkconfig files.
//

TOIT-MTU-TCP     ::= TOIT-MTU-BASE_ - TOIT-MTU-IP-HEADER-SIZE_ - TOIT-MTU-TCP-HEADER-SIZE_
TOIT-MTU-TCP-TLS ::= TOIT-MTU-TCP - TOIT-MTU-TCP-TLS-HEADER-SIZE_
TOIT-MTU-UDP     ::= TOIT-MTU-BASE_ - TOIT-MTU-IP-HEADER-SIZE_ - TOIT-MTU-UDP-HEADER-SIZE_

// We've seen issues with having a higher base than 1450 on some networks.
TOIT-MTU-BASE_                ::= 1450
TOIT-MTU-IP-HEADER-SIZE_      ::= 20
TOIT-MTU-UDP-HEADER-SIZE_     ::= 8
TOIT-MTU-TCP-HEADER-SIZE_     ::= 20
TOIT-MTU-TCP-TLS-HEADER-SIZE_ ::= 29
