// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface StorageService:
  static SELECTOR ::= ServiceSelector
      --uuid="ee91ed5e-85dd-47dd-a57a-7b6933fa58ea"
      --major=0
      --minor=1

  open_bucket --scheme/string --path/string -> int
  static OPEN_BUCKET_INDEX /int ::= 0

  get bucket/int key/string -> ByteArray?
  static GET_INDEX /int ::= 1

  set bucket/int key/string value/ByteArray -> none
  static SET_INDEX /int ::= 2

  remove bucket/int key/string -> none
  static REMOVE_INDEX /int ::= 3

class StorageServiceClient extends ServiceClient implements StorageService:
  static SELECTOR ::= StorageService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  open_bucket --scheme/string --path/string -> int:
    return invoke_ StorageService.OPEN_BUCKET_INDEX [scheme, path]

  get bucket/int key/string -> ByteArray?:
    return invoke_ StorageService.GET_INDEX [bucket, key]

  set bucket/int key/string value/ByteArray -> none:
    invoke_ StorageService.SET_INDEX [bucket, key, value]

  remove bucket/int key/string -> none:
    invoke_ StorageService.REMOVE_INDEX [bucket, key]
