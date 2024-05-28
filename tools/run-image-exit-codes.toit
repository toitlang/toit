// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/** A new firmware has been written and the system should switch to it. */
EXIT-CODE-UPGRADE ::= 17
/** A rollback has been requested. */
EXIT-CODE-ROLLBACK-REQUESTED ::= 18
/**
The system should stop.

This is usually only used in testing.
*/
EXIT-CODE-STOP ::= 19
