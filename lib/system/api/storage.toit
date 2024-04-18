// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface StorageService:
  static SELECTOR ::= ServiceSelector
      --uuid="ee91ed5e-85dd-47dd-a57a-7b6933fa58ea"
      --major=0
      --minor=3

  bucket-open --scheme/string --path/string -> int
  static BUCKET-OPEN-INDEX /int ::= 0

  bucket-get bucket/int key/string -> ByteArray?
  static BUCKET-GET-INDEX /int ::= 1

  bucket-set bucket/int key/string value/ByteArray -> none
  static BUCKET-SET-INDEX /int ::= 2

  bucket-remove bucket/int key/string -> none
  static BUCKET-REMOVE-INDEX /int ::= 3

  region-open --scheme/string --path/string --capacity/int? --writable/bool -> List
  static REGION-OPEN-INDEX /int ::= 4

  region-delete --scheme/string --path/string -> none
  static REGION-DELETE-INDEX /int ::= 5

  region-list --scheme/string -> List
  static REGION-LIST-INDEX /int ::= 6

class StorageServiceClient extends ServiceClient implements StorageService:
  static SELECTOR ::= StorageService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  bucket-open --scheme/string --path/string -> int:
    return invoke_ StorageService.BUCKET-OPEN-INDEX [scheme, path]

  bucket-get bucket/int key/string -> ByteArray?:
    return invoke_ StorageService.BUCKET-GET-INDEX [bucket, key]

  bucket-set bucket/int key/string value/ByteArray -> none:
    invoke_ StorageService.BUCKET-SET-INDEX [bucket, key, value]

  bucket-remove bucket/int key/string -> none:
    invoke_ StorageService.BUCKET-REMOVE-INDEX [bucket, key]

  region-open --scheme/string --path/string --capacity/int? --writable/bool -> List:
    return invoke_ StorageService.REGION-OPEN-INDEX [scheme, path, capacity, writable]

  region-delete --scheme/string --path/string -> none:
    invoke_ StorageService.REGION-DELETE-INDEX [scheme, path]

  region-list --scheme/string -> List:
    return invoke_ StorageService.REGION-LIST-INDEX scheme
