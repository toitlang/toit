// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import system.services

/**
The wire protocol of the experimental BLE service.

Providers (`ble.experimental.service.provider` and its variants) and the
  client (`ble.experimental.service.client`) share $SELECTOR and the method
  indices below; the `CAP-*` flags describe what a provider supports and
  $READ, $VALIDATE-WRITE and $WRITTEN are the kinds of application request a
  peripheral session pulls. Applications use the client rather than this
  library.
*/

// Experimental protocol: incompatible changes remain possible before release.
SELECTOR ::= services.ServiceSelector
    --uuid="9d28731e-2a9f-4b19-adf7-39717fae7622"
    --major=0
    --minor=32

OPEN ::= 0
NEXT ::= 1
REPLY ::= 2
WAIT-CLOSED ::= 3
VALUE ::= 4
SET-VALUE ::= 5
NOTIFY ::= 6
PEER ::= 7
OPEN-BUILDER ::= 8
ADD-SERVICE ::= 9
ADD-CHARACTERISTIC ::= 10
START ::= 11
OPEN-BOUNDED-BUILDER ::= 12
MTU ::= 13
INDICATE ::= 14
WAIT-INDICATION ::= 15
OPEN-SCAN ::= 16
SCAN-NEXT ::= 17
SCAN-STOP ::= 18
CAPABILITIES ::= 19
CONNECT ::= 20
CENTRAL-READY ::= 21
CENTRAL-READ ::= 22
CENTRAL-WRITE ::= 23
CENTRAL-SERVICES ::= 24
CENTRAL-CHARACTERISTICS ::= 25
CENTRAL-DESCRIPTORS ::= 26
CENTRAL-STOP ::= 27
CENTRAL-SUBSCRIBE ::= 28
CENTRAL-SUBSCRIPTION-READY ::= 29
CENTRAL-SUBSCRIPTION-NEXT ::= 30
CENTRAL-UNSUBSCRIBE ::= 31
CENTRAL-MONITOR ::= 32
CENTRAL-REVISION ::= 33
CENTRAL-CHECKED ::= 34
CENTRAL-WRITE-COMMAND ::= 35
ADD-DESCRIPTOR ::= 36
OPEN-ADVERTISING ::= 37
ADVERTISING-READY ::= 38
ADVERTISING-STOP ::= 39
SECURITY ::= 40
SET-HANDLER-TIMEOUT ::= 41
ADVERTISING-UPDATE ::= 42
PERIPHERAL-ADVERTISING-UPDATE ::= 43
NOTIFY-VALUES ::= 44
// Link operations, on both central connections and peripheral sessions.
LINK-INFO ::= 45
SET-PHY ::= 46
READ-RSSI ::= 47
READ-TX-POWER ::= 48
UPDATE-PARAMETERS ::= 49
WAIT-DISCONNECTED ::= 50
// Provider-wide operations.
ADAPTER-INFO ::= 51
SET-TX-POWER ::= 52
// More GATT client procedures on central connections.
CENTRAL-INCLUDED ::= 53
CENTRAL-READ-BY-UUID ::= 54
CENTRAL-READ-MULTIPLE ::= 55
// Peripheral builder: an include in the latest service.
INCLUDE-SERVICE ::= 56
// Peripheral sessions accept the CENTRAL-* GATT client operations too
// (minor 30): they reach the connected central's database.
// Provider-wide: the peers a deployment lists as bonded.
BONDED-PEERS ::= 57
// Link: the application asks for security (a Security Request as peripheral).
REQUEST-SECURITY ::= 58
// Link: this connection's transmit power (vendor control).
SET-LINK-TX-POWER ::= 59

CAP-SCAN ::= 1
CAP-GATT-PERIPHERAL ::= 2
CAP-GATT-CENTRAL ::= 4
CAP-ADVERTISING ::= 8
CAP-CONTINUOUS-SCAN ::= 16
CAP-MIXED-ROLES ::= 32

READ ::= 1
VALIDATE-WRITE ::= 2
WRITTEN ::= 3
