// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import uuid
import system.services show ServiceSelector ServiceClient
import system.containers show ContainerImage

interface ContainerService:
  static SELECTOR ::= ServiceSelector
      --uuid="358ee529-45a4-409e-8fab-7a28f71e5c51"
      --major=0
      --minor=7

  static FLAG-RUN-BOOT     /int ::= 1 << 0
  static FLAG-RUN-CRITICAL /int ::= 1 << 1
  // Containers from images with this flag always run with the untrusted
  // (sandbox) policy.
  static FLAG-UNTRUSTED    /int ::= 1 << 2

  // Policy kinds. Keep in sync with PrimitivePolicy::Kind in
  // src/primitive_policy.h.
  static POLICY-TRUSTED   /int ::= 1
  static POLICY-UNTRUSTED /int ::= 2

  list-images -> List
  static LIST-IMAGES-INDEX /int ::= 0

  load-image id/uuid.Uuid -> List?
  static LOAD-IMAGE-INDEX /int ::= 1

  /**
  Starts the container with the given $handle.

  The $policy is null (use the default of the image) or a policy kind
    (see $POLICY-TRUSTED).
  */
  start-container handle/int arguments/any --policy/any=null -> none
  static START-CONTAINER-INDEX /int ::= 7

  stop-container handle/int -> none
  static STOP-CONTAINER-INDEX /int ::= 6

  uninstall-image id/uuid.Uuid -> none
  static UNINSTALL-IMAGE-INDEX /int ::= 2

  image-writer-open size/int -> int
  static IMAGE-WRITER-OPEN-INDEX /int ::= 3

  image-writer-write handle/int bytes/ByteArray -> none
  static IMAGE-WRITER-WRITE-INDEX /int ::= 4

  image-writer-commit handle/int flags/int data/int -> uuid.Uuid
  static IMAGE-WRITER-COMMIT-INDEX /int ::= 5

  notify-background-state-changed new-state/any -> none
  static NOTIFY-BACKGROUND-STATE-CHANGED-INDEX /int ::= 8

class ContainerServiceClient extends ServiceClient implements ContainerService:
  static SELECTOR ::= ContainerService.SELECTOR
  constructor selector/ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  list-images -> List:
    array := invoke_ ContainerService.LIST-IMAGES-INDEX null
    return List array.size / 4:
      cursor := it * 4
      ContainerImage
          --id=uuid.Uuid array[cursor]
          --name=array[cursor + 1]
          --flags=array[cursor + 2]
          --data=array[cursor + 3]

  load-image id/uuid.Uuid -> List?:
    return invoke_ ContainerService.LOAD-IMAGE-INDEX id.to-byte-array

  start-container handle/int arguments/any --policy/any=null -> none:
    invoke_ ContainerService.START-CONTAINER-INDEX [handle, arguments, policy]

  stop-container handle/int -> none:
    invoke_ ContainerService.STOP-CONTAINER-INDEX handle

  uninstall-image id/uuid.Uuid -> none:
    invoke_ ContainerService.UNINSTALL-IMAGE-INDEX id.to-byte-array

  image-writer-open size/int -> int:
    return invoke_ ContainerService.IMAGE-WRITER-OPEN-INDEX size

  image-writer-write handle/int bytes/ByteArray -> none:
    invoke_ ContainerService.IMAGE-WRITER-WRITE-INDEX [handle, bytes]

  image-writer-commit handle/int flags/int data/int -> uuid.Uuid:
    return uuid.Uuid (invoke_ ContainerService.IMAGE-WRITER-COMMIT-INDEX [handle, flags, data])

  notify-background-state-changed new-state/bool -> none:
    invoke_ ContainerService.NOTIFY-BACKGROUND-STATE-CHANGED-INDEX new-state
