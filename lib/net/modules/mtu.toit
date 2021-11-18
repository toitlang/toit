// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

// IMPORTANT
// =========
// On the ESP32, the TOIT_MTU_TCP should match CONFIG_TCP_MSS and CONFIG_LWIP_TCP_MSS
// from the sdkconfig files.
//

TOIT_MTU_TCP     ::= TOIT_MTU_BASE_ - TOIT_MTU_IP_HEADER_SIZE_ - TOIT_MTU_TCP_HEADER_SIZE_
TOIT_MTU_TCP_TLS ::= TOIT_MTU_TCP - TOIT_MTU_TCP_TLS_HEADER_SIZE_
TOIT_MTU_UDP     ::= TOIT_MTU_BASE_ - TOIT_MTU_IP_HEADER_SIZE_ - TOIT_MTU_UDP_HEADER_SIZE_

// We've seen issues with having a higher base than 1450 on some networks.
TOIT_MTU_BASE_                ::= 1450
TOIT_MTU_IP_HEADER_SIZE_      ::= 20
TOIT_MTU_UDP_HEADER_SIZE_     ::= 8
TOIT_MTU_TCP_HEADER_SIZE_     ::= 20
TOIT_MTU_TCP_TLS_HEADER_SIZE_ ::= 29
