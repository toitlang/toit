// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto
import crypto.aes
import .bond show Candidate

/**
Sealing of bond records for storage in an untrusted byte store.

$Protection encrypts and authenticates a $Candidate with AES-GCM under a
  caller-provisioned 32-byte key ($Protection.seal), binding each record to
  its storage namespace and slot, and only returns a decoded candidate after
  the whole record has been authenticated ($Protection.open). `bond-storage`
  uses it for every record it writes and reads; the key comes from the
  deployment, for example `storage-key`.
*/

HEADER_ ::= #[0x54, 0x42, 0x53, 1]

/**
Encrypts candidate records with a caller-provisioned 256-bit storage key.

The key must be protected independently of the record backend. Each seal uses
  a fresh random 96-bit GCM nonce. Across all instances and restarts, rotate a
  key before 2^32 seals. The caller must supply a stable, trusted context naming
  the storage namespace and record slot; loading with another context fails.

This protects confidentiality and integrity, not rollback or deletion. Replaying
  a previously valid record remains possible unless the backend supplies a
  trusted generation/deletion policy. It does not establish durable commit or
  peer delivery. Keep this optional module in the trusted BLE provider.
*/
class Protection:
  key_/ByteArray? := ?

  constructor key/ByteArray:
    if key.size != 32: throw "INVALID_ARGUMENT"
    key_ = key.copy

  /** Returns an owned sealed record suitable for an untrusted byte store. */
  seal candidate/Candidate --context/ByteArray -> ByteArray:
    key := require-key_
    aad := associated-data_ context
    nonce := crypto.random --size=12
    encryptor := aes.AesGcm.encryptor key nonce
    try:
      encrypted := encryptor.encrypt candidate.encode --authenticated-data=aad
      return HEADER_ + nonce + encrypted
    finally:
      encryptor.close

  /** Authenticates the entire record before decoding or returning any secrets. */
  open bytes/ByteArray --context/ByteArray -> Candidate:
    key := require-key_
    aad := associated-data_ context
    // Header, nonce, the shortest record and the tag; the decoded record
    // checks its own length per version.
    if bytes.size < 98 or bytes[..4] != HEADER_: throw "BLE_INVALID_SEALED_BOND"
    decryptor := aes.AesGcm.decryptor key bytes[4..16]
    try:
      plaintext/ByteArray? := null
      error := catch:
        plaintext = decryptor.decrypt bytes[16..] --authenticated-data=aad
      if error == "INVALID_SIGNATURE": throw "BLE_INVALID_SEALED_BOND"
      if error: throw error
      return Candidate.decode plaintext
    finally:
      decryptor.close

  /** Drops the key reference; does not promise erasure of compacting-GC copies. */
  close -> none:
    key_ = null

  require-key_ -> ByteArray:
    key := key_
    if not key: throw "BLE_BOND_PROTECTION_CLOSED"
    return key

associated-data_ context/ByteArray -> ByteArray:
  if not 1 <= context.size <= 128: throw "INVALID_ARGUMENT"
  return "toit.ble.bond".to-byte-array + HEADER_ + #[context.size] + context
