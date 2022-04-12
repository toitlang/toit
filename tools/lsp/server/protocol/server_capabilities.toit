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

import ..rpc

import .experimental

class InitializationResult extends MapWrapper:
  /**
  Creates a response object for initialization.

  Parameters:
  - [capabilities]: the capabilities of the server.
  */
  constructor
      capabilities /ServerCapabilities:
    map_["capabilities"] = capabilities

/**
Defines how the host (editor) should sync document changes to the language server.
*/
// TODO(florian): this should be an enum.
class TextDocumentSyncKind:
  /**
  Documents should not be synced at all.
  */
  static none ::= 0

  /**
  Documents are synced by always sending the full content of the document.
  */
  static full ::= 1

  /**
  Documents are synced by sending the full content on open.
  After that only incremental updates to the document are sent.
  */
  static incremental ::= 2

/**
Completion options.
*/
class CompletionOptions extends MapWrapper:

  /**
  Creates a response object for completion options.

  Parameters:
  - [resolve_provider]: whether the server provides support to resolve
    additional information for a completion item.
  - [trigger_characters]: the characters that trigger completion automatically.
  */
  constructor
      --resolve_provider   /bool?             = null
      --trigger_characters /List?/*<string>*/ = null:
    map_["resolveProvider"]   = resolve_provider
    map_["triggerCharacters"] = trigger_characters

/**
Signature help options.
*/
class SignatureHelpOptions extends MapWrapper:

  /**
  Creates a response object for signature-help options.

  Parameters:
  - [trigger_characters]: the characters that trigger signature help automatically.
  */
  constructor
      trigger_characters /List?/*<string>*/ = null:
    map_["triggerCharacters"] = trigger_characters

/**
Code Action options.
*/
class CodeActionOptions extends MapWrapper:
  /**
  Creates a response object for code-action options.

  Parameters:
  - [code_action_kinds]: The [CodeActionKinds] that this server may return.
    The list of kinds may be generic, such as `CodeActionKind.Refactor`, or the server
      may list out every specific kind they provide.
  */
  constructor
      code_action_kinds /List?/*<string>*/ = null:
    map_["codeActionKinds"] = code_action_kinds


/**
Code Lens options.
*/
class CodeLensOptions extends MapWrapper:
  /**
  Creates a response object for code-lens options.

  Parameters:
  - [resolve_provider]: Whether code lens has a resolve provider as well.
  */
  constructor
      resolve_provider /bool? = null:
    map_["resolveProvider"] = resolve_provider

/**
Format document on type options.
*/
class DocumentOnTypeFormattingOptions extends MapWrapper:
  /**
  Creates a response object for document-on-type-formatting options.

  Parameters:
  - [first_trigger_character]: a character on which formatting should be
    triggered, like `}`.
  - [more_trigger_characters]: more trigger characters.
  */
  constructor
      first_trigger_character /string            = null
      more_trigger_characters /List?/*<string>*/ = null:
    map_["firstTriggerCharacter"] = first_trigger_character
    map_["moreTriggerCharacters"] = more_trigger_characters

/**
Rename options.
*/
class RenameOptions extends MapWrapper:
  /**
  Creates a response object for rename options.

  Parameters:
  - [prepare_provider]: whether renames should be checked and tested before being executed.
  */
  constructor
      prepare_provider /bool? = null:
    map_["prepareProvider"] = prepare_provider

/**
Document link options.
*/
class DocumentLinkOptions extends MapWrapper:
  /**
  Creates a response object for document-link options.

  Parameters:
  - [resolve_provider]: whether document links have a resolve provider as well.
  */
  constructor
      resolve_provider /bool? = null:
    map_["resolveProvider"] = resolve_provider

/**
Execute command options.
*/
class ExecuteCommandOptions extends MapWrapper:
  /**
  Creates a response object for execute-command options.

  Parameters:
  - [commands]: the commands to be executed on the server
  */
  constructor
      commands /List/*<string>*/ = null:
    map_["commands"] = commands

/**
Save options.
*/
class SaveOptions extends MapWrapper:
  /**
  Creates a response object for save options.

  Parameters:
  - [include_text]: whether the client is supposed to include the content on save.
  */
  constructor
      --include_text /bool? = null:
    map_["includeText"] = include_text

/**
Color provider options.
*/
class ColorProviderOptions extends MapWrapper:

/**
Folding range provider options.
*/
class FoldingRangeProviderOptions extends MapWrapper:

class TextDocumentSyncOptions extends MapWrapper:
  /**
  Creates a response object for text-document-sync options.

  Parameters:
  - [open_close]: whether open and close notifications are sent to the server.
  - [change]: Which change notifications (a [TextDocumentSyncKind]) are sent to the server.
    If omitted it defaults to [TextDocumentSyncKind.none].
  - [will_save]: whether will-save notifications are sent to the server.
  - [will_save_wait_until]: whether will-save-wait-until requests are sent to the server.
  - [save]: the save notifications that are sent to the server.
  */
  constructor
      --open_close           /bool?        = null
      --change               /int?         = null // A [TextDocumentSyncKind]
      --will_save            /bool?        = null
      --will_save_wait_until /bool?        = null
      --save                 /SaveOptions? = null:
    map_["openClose"]         = open_close
    map_["change"]            = change
    map_["willSave"]          = will_save
    map_["willSaveWaitUntil"] = will_save_wait_until
    map_["save"]              = save


/**
Static registration options to be returned in the initialize request.
*/
class StaticRegistrationOptions extends MapWrapper:
  /**
  Creates a response object for static-registration options.

  Parameters:
  - [id]: the id used to register the request. The id can be used to deregister
    the request again. See also [Registration.id].
  */
  constructor
      id /string? = null:
    map_["id"] = id

class SemanticTokensLegend extends MapWrapper:
  /**
  Creates a response object for semantic-tokens legends options.
  */
  constructor
      --token_types     /List/*<string>*/
      --token_modifiers /List/*<string>*/:
    map_["tokenTypes"] = token_types
    map_["tokenModifiers"] = token_modifiers

class SemanticTokensOptions extends MapWrapper:
  /**
  Creates a response object for semantic-tokens options.

  Parameters:
  - [open_close]: whether open and close notifications are sent to the server.
  - [change]: Which change notifications (a [TextDocumentSyncKind]) are sent to the server.
    If omitted it defaults to [TextDocumentSyncKind.none].
  - [will_save]: whether will-save notifications are sent to the server.
  - [will_save_wait_until]: whether will-save-wait-until requests are sent to the server.
  - [save]: the save notifications that are sent to the server.
  */
  constructor
      --legend /SemanticTokensLegend
      --range  /bool?
      --full   /any: // boolean | {delta?: boolean}
    map_["legend"] = legend
    map_["range"] = range
    map_["full"] = full

/**
*/
class WorkspaceFoldersServerCapabilities extends MapWrapper:
  /**
  Creates a response object for workspace server-capabilities.

  Parameters:
  - [supported]: whether the server has support for workspace folders.
  - [change_notifications]: whether the server wants to receive workspace folder
    change notifications.
    If a strings is provided the string is treated as a ID
      under which the notification is registered on the client
      side. The ID can be used to unregister for these events
      using the `client/unregisterCapability` request.
  */
  constructor
      supported            /bool? = null
      change_notifications /any   = null:  /* string | bool | Null */
    map_["supported"] = supported
    map_["changeNotifications"] = change_notifications

/**
The workspace-specific server-capabilities.
*/
class WorkspaceServerCapabilities extends MapWrapper:
  /**
  Creates a response object for workspace server-capabilities.

  Parameters:
  - [workspace_folders]: The workspace-folder support.
  */
  constructor
      workspace_folders /WorkspaceFoldersServerCapabilities? = null:
    map_["workspaceFolders"] = workspace_folders



class ServerCapabilities extends MapWrapper:
  /**
  Creates a response object for server capabilities.

  Parameters:
  - [text_document_sync]: defines how text documents are synced.
    If omitted it defaults to no synchronization.
  - [hover_provider]: whether the server provides hover support.
  - [completion_provider]: the completion support the server provides.
  - [signature_help_provider]: the signature-help support the server provides.
  - [definition_provider]: whether the server provides definition support.
  - [type_definition_provider]: whether the server provides goto-type-definition support.
    TODO(florian): this can be either a boolean or a class that implements both
      TextDocumentRegistrationOptions & StaticRegistrationOptions. For this to work we
      need to have interfaces (and then figure out how to type it.)
  - [implementation_provider]: whether the server provides goto-implementation support.
    TODO(florian): Same as for [type_definition_provider].
  - [references_provider]: whether the server provides find-references support.
  - [document_highlight_provider]: whether the server provides document-highlight support.
  - [document_symbol_provider]: whether the server provides document-symbol support.
  - [workspace_symbol_provider]: whether the server provides workspace-symbol support.
  - [code_action_provider]: the code-action support the server provides. The
      `CodeActionOptions` return type is only valid if the client signals code action
      literal support via the property
      [CodeActionLiteralSupportCapabilities.code_action_literal_support].
  - [code_lens_provider]: the code-lens support the server provides.
  - [document_formatting_provider]: whether the server provides document formatting.
  - [document_range_formatting_provider]: whether the server provides document range formatting.
  - [document_on_type_formatting_provider]: the document-on-type-formatting options the
    server supports.
  - [rename_provider]: the renaming support the server provides.
    RenameOptions may only be specified if the client states that it supports
    [RenameCapabilities.prepare_support] in its initial `initialize` request.
  - [document_link_provider]: the document-link support the server provides.
  - [color_provider]: the color support the server provides.
  - [folding_range_provider]: the folding-provider the server supports.
  - [execute_command_provider]: the execute-command support the server supports.
  - [workspace]: the workspace-specific server capabilities.
  - [experimental]: experimental server capabilities.
  */
  constructor
      --text_document_sync       /any                   = null /* TextDocumentSyncOptions | int | Null */
      --hover_provider           /bool?                 = null
      --completion_provider      /CompletionOptions?    = null
      --signature_help_provider  /SignatureHelpOptions? = null
      --definition_provider      /bool?                 = null
      --type_definition_provider /any                   = null /* bool | (TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --implementation_provider  /any                   = null /* bool | (TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --references_provider      /bool?                 = null
      --document_highlight_provider  /bool?             = null
      --document_symbol_provider     /bool?             = null
      --workspace_symbol_provider    /bool?             = null
      --code_action_provider         /any               = null /* bool | CodeActionOptions | Null */
      --code_lens_provider           /CodeLensOptions?  = null
      --document_formatting_provider /bool?             = null
      --document_range_formatting_provider   /bool?     = null
      --document_on_type_formatting_provider /DocumentOnTypeFormattingOptions? = null
      --rename_provider          /any                          = null /* bool | RenameOptions | Null */
      --document_link_provider   /DocumentLinkOptions?         = null
      --color_provider           /any                          = null /* bool | ColorProviderOptions | (ColorProviderOptions & TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --folding_range_provider   /any                          = null /* bool | FoldingRangeProviderOptions | (FoldingRangeProviderOptions & TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --execute_command_provider /ExecuteCommandOptions?       = null
      --semantic_tokens_provider /SemanticTokensOptions?       = null
      --workspace                /WorkspaceServerCapabilities? = null
      --experimental             /Experimental?                = null:
    map_["textDocumentSync"]       = text_document_sync
    map_["hoverProvider"]          = hover_provider
    map_["completionProvider"]     = completion_provider
    map_["signatureHelpProvider"]  = signature_help_provider
    map_["definitionProvider"]     = definition_provider
    map_["typeDefinitionProvider"] = type_definition_provider
    map_["implementationProvider"] = implementation_provider
    map_["referencesProvider"]     = references_provider
    map_["documentHighlightProvider"]  = document_highlight_provider
    map_["documentSymbolProvider"]     = document_symbol_provider
    map_["workspaceSymbolProvider"]    = workspace_symbol_provider
    map_["codeActionProvider"]         = code_action_provider
    map_["codeLensProvider"]           = code_lens_provider
    map_["documentFormattingProvider"] = document_formatting_provider
    map_["documentRangeFormattingProvider"]  = document_range_formatting_provider
    map_["documentOnTypeFormattingProvider"] = document_on_type_formatting_provider
    map_["renameProvider"]         = rename_provider
    map_["documentLinkProvider"]   = document_link_provider
    map_["colorProvider"]          = color_provider
    map_["foldingRangeProvider"]   = folding_range_provider
    map_["executeCommandProvider"] = execute_command_provider
    map_["semanticTokensProvider"] = semantic_tokens_provider
    map_["workspace"]              = workspace
    map_["experimental"]           = experimental
