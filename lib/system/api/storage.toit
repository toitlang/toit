// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface StorageService:
  static SELECTOR ::= ServiceSelector
      --uuid="ee91ed5e-85dd-47dd-a57a-7b6933fa58ea"
      --major=0
      --minor=2

  bucket_open --scheme/string --path/string -> int
  static BUCKET_OPEN_INDEX /int ::= 0

  bucket_get bucket/int key/string -> ByteArray?
  static BUCKET_GET_INDEX /int ::= 1

  bucket_set bucket/int key/string value/ByteArray -> none
  static BUCKET_SET_INDEX /int ::= 2

  bucket_remove bucket/int key/string -> none
  static BUCKET_REMOVE_INDEX /int ::= 3

  region_open --scheme/string --path/string --minimum_size/int -> List
  static REGION_OPEN_INDEX /int ::= 4

  region_delete --scheme/string --path/string -> none
  static REGION_DELETE_INDEX /int ::= 5

  region_list --scheme/string -> List
  static REGION_LIST_INDEX /int ::= 6

class StorageServiceClient extends ServiceClient implements StorageService:
  static SELECTOR ::= StorageService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  bucket_open --scheme/string --path/string -> int:
    return invoke_ StorageService.BUCKET_OPEN_INDEX [scheme, path]

  bucket_get bucket/int key/string -> ByteArray?:
    return invoke_ StorageService.BUCKET_GET_INDEX [bucket, key]

  bucket_set bucket/int key/string value/ByteArray -> none:
    invoke_ StorageService.BUCKET_SET_INDEX [bucket, key, value]

  bucket_remove bucket/int key/string -> none:
    invoke_ StorageService.BUCKET_REMOVE_INDEX [bucket, key]

  region_open --scheme/string --path/string --minimum_size/int -> List:
    return invoke_ StorageService.REGION_OPEN_INDEX [scheme, path, minimum_size]

  region_delete --scheme/string --path/string -> none:
    invoke_ StorageService.REGION_DELETE_INDEX [scheme, path]

  region_list --scheme/string -> List:
    return invoke_ StorageService.REGION_LIST_INDEX scheme
