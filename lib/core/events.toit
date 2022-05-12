// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

read_state_ module id:
  #primitive.events.read_state

register_object_notifier_ monitor/__Monitor__? module id -> none:
  #primitive.events.register_object_notifier

unregister_object_notifier_ module id:
  #primitive.events.unregister_object_notifier
