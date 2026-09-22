// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import system.services

// Optional administration protocol, separate from ordinary BLE operations.
SELECTOR ::= services.ServiceSelector
    --uuid="e5cfa11d-240f-4530-b45e-40a1277eb696"
    --major=0
    --minor=3

REVOKE ::= 0
BONDS ::= 1
BONDS-WITH-REVISION ::= 2
REVOKE-IF-CURRENT ::= 3
