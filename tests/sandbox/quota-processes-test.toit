// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .sandbox

// The process quota is enforced on spawn (here for a trusted container
// with a quota, since untrusted containers can't spawn at all).
main args:
  sandbox-test args --trusted --error="QUOTA_EXCEEDED" --quotas={"processes": 2}: | arguments/Map |
    spawn:: sleep --ms=500
    spawn:: sleep --ms=500
