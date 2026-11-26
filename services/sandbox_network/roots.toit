// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
The root certificates that clients of the sandbox network provider bring.

The provider has no roots of its own and installs none in its process: a
  client registers the roots it trusts with its session, and they are given
  to its own TLS connections only (`--root-certificates`), so one client's
  roots never decide another client's verification. A root is kept as its
  DER bytes, stored once for all clients that registered it (by its SHA-256,
  with a count of its users), and parsed (by mbedTLS, in this process) only
  when a TLS connection first uses it. Per client: at most
  $MAX-CLIENT-ROOTS roots of $MAX-CLIENT-ROOT-BYTES together, freed when the
  client closes.
*/

import crypto.sha256
import encoding.base64
import net.x509
import system.api.sandbox-network show MAX-CLIENT-ROOTS MAX-CLIENT-ROOT-BYTES CHUNK-SIZE

class RootEntry:
  der/ByteArray
  hash/ByteArray
  users_/int := 0
  parsed_/x509.Certificate? := null

  constructor .der .hash:

  /** The parsed certificate; throws TLS_FAILED if it can't be parsed. */
  parsed -> x509.Certificate:
    if not parsed_:
      exception := catch: parsed_ = x509.Certificate.parse der
      if exception: throw "TLS_FAILED"
    return parsed_

/** The roots of all clients, each stored once. */
class RootStore:
  entries_/Map ::= {:}  // Map<ByteArray, RootEntry>, by SHA-256.

  acquire der/ByteArray -> RootEntry:
    hash := sha256.sha256 der
    entry := entries_.get hash --init=: RootEntry der hash
    entry.users_++
    return entry

  release entry/RootEntry -> none:
    entry.users_--
    if entry.users_ == 0: entries_.remove entry.hash

  /** The number of stored roots and their bytes (DER). */
  stats -> List:
    bytes := 0
    entries_.do --values: bytes += it.der.size
    return [entries_.size, bytes]

/** The roots one client registered. */
class ClientRoots:
  store_/RootStore
  roots_/Map ::= {:}    // Map<int, RootEntry>, by id.
  bytes_/int := 0
  next-id_/int := 1
  upload_/ByteArray? := null  // A root being uploaded in chunks.
  uploaded_/int := 0

  constructor .store_:

  /**
  Takes a chunk of a root of $total bytes at $offset. Returns the root's id
    when it is complete, null before.
  */
  add total/int offset/int chunk/ByteArray -> int?:
    if total <= 0 or chunk.size > CHUNK-SIZE: throw "INVALID_ARGUMENT"
    if roots_.size >= MAX-CLIENT-ROOTS or bytes_ + total > MAX-CLIENT-ROOT-BYTES:
      upload_ = null
      throw "NETWORK_QUOTA_EXCEEDED"
    if offset == 0:
      upload_ = ByteArray total
      uploaded_ = 0
    if not upload_ or upload_.size != total or offset != uploaded_ or offset + chunk.size > total:
      upload_ = null
      throw "INVALID_ARGUMENT"
    upload_.replace offset chunk
    uploaded_ += chunk.size
    if uploaded_ < total: return null
    data := upload_
    upload_ = null
    der := to-der_ data
    entry := store_.acquire der
    bytes_ += total
    id := next-id_++
    roots_[id] = entry
    return id

  /**
  The roots with the given $ids (all of them if null). Throws
    INVALID_ARGUMENT for an unknown id.
  */
  select ids/List? -> List:
    if not ids: return roots_.values
    return ids.map: | id |
      roots_.get id --if-absent=: throw "INVALID_ARGUMENT"

  /** Gives the roots back to the store (the client closed). */
  release -> none:
    roots_.do --values: store_.release it
    roots_.clear
    bytes_ = 0

  // PEM to DER; DER (or anything else) as is: mbedTLS refuses what isn't a
  // certificate when a connection first uses it.
  static to-der_ data/ByteArray -> ByteArray:
    BEGIN ::= "-----BEGIN CERTIFICATE-----"
    END ::= "-----END CERTIFICATE-----"
    if data.size < BEGIN.size or data[..BEGIN.size].to-string-non-throwing != BEGIN:
      return data
    text := data.to-string-non-throwing
    end := text.index-of END
    if end < 0: throw "INVALID_ARGUMENT"
    body := (text[BEGIN.size..end].split "\n").map: it.trim
    exception := catch: return base64.decode (body.join "")
    throw "INVALID_ARGUMENT"
