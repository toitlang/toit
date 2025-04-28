// Copyright (C) 2019 Toitware ApS.
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

import .document
import ..rpc

/**
How a completion was triggered.
*/
interface CompletionTriggerKind:
  /**
  Completion was triggered by typing an identifier (24x7 code
    complete), manual invocation (e.g Ctrl+Space) or via API.
  */
  static invoked ::= 1

  /**
  Completion was triggered by a trigger character specified by
    the `triggerCharacters` properties of the `CompletionRegistrationOptions`.
  */
  static trigger-character ::= 2

  /**
  Completion was re-triggered as the current completion list is incomplete.
  */
  static trigger-for-incomplete-completions ::= 3


/**
Contains additional information about the context in which a completion request is triggered.
*/
class CompletionContext extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  How the completion was triggered.
   */
  trigger-kind -> int:  // A CompletionTriggerKind
    return at_ "trigger_kind"

  /**
  The trigger character (a single character) that has trigger code complete.
    Is undefined if `triggerKind !== CompletionTriggerKind.TriggerCharacter`
  */
  trigger-character -> string?:
    return lookup_ "triggerCharacter"

class CompletionParams extends TextDocumentPositionParams:
  constructor json-map/Map: super json-map

  /**
  The completion context. This is only available if the client specifies
    to send this using `ClientCapabilities.textDocument.completion.contextSupport === true`
  */
  context -> CompletionContext?:
    return lookup_ "context": CompletionContext it

class CompletionItem extends MapWrapper:
  /**
  Creates a completion item.
  If $kind is equal to -1, indicates that no kind was provided.
  */
  constructor
      --label /string
      --kind  /int:
    map_["label"] = label
    if kind != -1: map_["kind"] = kind

  set-text-edit edit/TextEdit: map_["textEdit"] = edit
  label -> string: return at_ "label"

/**
A collection of $CompletionItem elements.
*/
class CompletionList extends MapWrapper:
  /**
  Creates a completion-list.

  If $is-incomplete is true, indicates that the completion list is not complete.
  */
  constructor
      --items         /List  // of CompletionItem
      --is-incomplete /bool = false
      --item-defaults /CompletionItemDefaults?:
    map_["items"] = items
    if is-incomplete: map_["isIncomplete"] = is-incomplete
    if item-defaults: map_["itemDefaults"] = item-defaults

/**
Properties that are shared among many completion items, and are
the default if not overridden by the individual completion items.
*/
class CompletionItemDefaults extends MapWrapper:
  /**
  Creates a new instance.

  The $edit-range specifies the range of the document that should be replaced by
    the completion item. It's the "prefix" of the completion items.
  */
  constructor
      --edit-range /Range?:
    if edit-range: map_["editRange"] = edit-range
