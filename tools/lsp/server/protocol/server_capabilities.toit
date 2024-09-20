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

import .code-action  // For Toitdocs.
import .initialization  // For Toitdocs.
import .experimental

class InitializationResult extends MapWrapper:
  /**
  Creates a response object for initialization.

  Parameters:
  - $capabilities: the capabilities of the server.
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
  - $resolve_provider: whether the server provides support to resolve
    additional information for a completion item.
  - $trigger_characters: the characters that trigger completion automatically.
  */
  constructor
      --resolve-provider   /bool?             = null
      --trigger-characters /List?/*<string>*/ = null:
    map_["resolveProvider"]   = resolve-provider
    map_["triggerCharacters"] = trigger-characters

/**
Signature help options.
*/
class SignatureHelpOptions extends MapWrapper:

  /**
  Creates a response object for signature-help options.

  Parameters:
  - $trigger_characters: the characters that trigger signature help automatically.
  */
  constructor
      trigger-characters /List?/*<string>*/ = null:
    map_["triggerCharacters"] = trigger-characters

/**
Code Action options.
*/
class CodeActionOptions extends MapWrapper:
  /**
  Creates a response object for code-action options.

  Parameters:
  - $code_action_kinds: The $CodeActionKind s that this server may return.
    The list of kinds may be generic, such as $CodeActionKind.refactor, or the server
      may list out every specific kind they provide.
  */
  constructor
      code-action-kinds /List?/*<string>*/ = null:
    map_["codeActionKinds"] = code-action-kinds


/**
Code Lens options.
*/
class CodeLensOptions extends MapWrapper:
  /**
  Creates a response object for code-lens options.

  Parameters:
  - $resolve_provider: Whether code lens has a resolve provider as well.
  */
  constructor
      resolve-provider /bool? = null:
    map_["resolveProvider"] = resolve-provider

/**
Format document on type options.
*/
class DocumentOnTypeFormattingOptions extends MapWrapper:
  /**
  Creates a response object for document-on-type-formatting options.

  Parameters:
  - $first_trigger_character: a character on which formatting should be
    triggered, like `}`.
  - $more_trigger_characters: more trigger characters.
  */
  constructor
      first-trigger-character /string            = null
      more-trigger-characters /List?/*<string>*/ = null:
    map_["firstTriggerCharacter"] = first-trigger-character
    map_["moreTriggerCharacters"] = more-trigger-characters

/**
Rename options.
*/
class RenameOptions extends MapWrapper:
  /**
  Creates a response object for rename options.

  Parameters:
  - $prepare_provider: whether renames should be checked and tested before being executed.
  */
  constructor
      prepare-provider /bool? = null:
    map_["prepareProvider"] = prepare-provider

/**
Document link options.
*/
class DocumentLinkOptions extends MapWrapper:
  /**
  Creates a response object for document-link options.

  Parameters:
  - $resolve_provider: whether document links have a resolve provider as well.
  */
  constructor
      resolve-provider /bool? = null:
    map_["resolveProvider"] = resolve-provider

/**
Execute command options.
*/
class ExecuteCommandOptions extends MapWrapper:
  /**
  Creates a response object for execute-command options.

  Parameters:
  - $commands: the commands to be executed on the server
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
  - $include_text: whether the client is supposed to include the content on save.
  */
  constructor
      --include-text /bool? = null:
    map_["includeText"] = include-text

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
  - $open_close: whether open and close notifications are sent to the server.
  - $change: Which change notifications (a $TextDocumentSyncKind) are sent to the server.
    If omitted it defaults to $TextDocumentSyncKind.none.
  - $will_save: whether will-save notifications are sent to the server.
  - $will_save_wait_until: whether will-save-wait-until requests are sent to the server.
  - $save: the save notifications that are sent to the server.
  */
  constructor
      --open-close           /bool?        = null
      --change               /int?         = null // A [TextDocumentSyncKind]
      --will-save            /bool?        = null
      --will-save-wait-until /bool?        = null
      --save                 /SaveOptions? = null:
    map_["openClose"]         = open-close
    map_["change"]            = change
    map_["willSave"]          = will-save
    map_["willSaveWaitUntil"] = will-save-wait-until
    map_["save"]              = save


/**
Static registration options to be returned in the initialize request.
*/
class StaticRegistrationOptions extends MapWrapper:
  /**
  Creates a response object for static-registration options.

  Parameters:
  - $id: the id used to register the request. The id can be used to deregister
    the request again.
  */
  constructor
      id /string? = null:
    map_["id"] = id

class SemanticTokensLegend extends MapWrapper:
  /**
  Creates a response object for semantic-tokens legends options.
  */
  constructor
      --token-types     /List/*<string>*/
      --token-modifiers /List/*<string>*/:
    map_["tokenTypes"] = token-types
    map_["tokenModifiers"] = token-modifiers

class SemanticTokensOptions extends MapWrapper:
  /**
  Creates a response object for semantic-tokens options.
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
  - $supported: whether the server has support for workspace folders.
  - $change_notifications: whether the server wants to receive workspace folder
    change notifications.
    If a strings is provided the string is treated as a ID
      under which the notification is registered on the client
      side. The ID can be used to unregister for these events
      using the `client/unregisterCapability` request.
  */
  constructor
      supported            /bool? = null
      change-notifications /any   = null:  /* string | bool | Null */
    map_["supported"] = supported
    map_["changeNotifications"] = change-notifications

/**
The workspace-specific server-capabilities.
*/
class WorkspaceServerCapabilities extends MapWrapper:
  /**
  Creates a response object for workspace server-capabilities.

  Parameters:
  - $workspace_folders: The workspace-folder support.
  */
  constructor
      workspace-folders /WorkspaceFoldersServerCapabilities? = null:
    map_["workspaceFolders"] = workspace-folders



class ServerCapabilities extends MapWrapper:
  /**
  Creates a response object for server capabilities.

  Parameters:
  - $text_document_sync: defines how text documents are synced.
    If omitted it defaults to no synchronization.
  - $hover_provider: whether the server provides hover support.
  - $completion_provider: the completion support the server provides.
  - $signature_help_provider: the signature-help support the server provides.
  - $definition_provider: whether the server provides definition support.
  - $type_definition_provider: whether the server provides goto-type-definition support.
    TODO(florian): this can be either a boolean or a class that implements both
      TextDocumentRegistrationOptions & StaticRegistrationOptions. For this to work we
      need to have interfaces (and then figure out how to type it.)
  - $implementation_provider: whether the server provides goto-implementation support.
    TODO(florian): Same as for $type_definition_provider.
  - $references_provider: whether the server provides find-references support.
  - $document_highlight_provider: whether the server provides document-highlight support.
  - $document_symbol_provider: whether the server provides document-symbol support.
  - $workspace_symbol_provider: whether the server provides workspace-symbol support.
  - $code_action_provider: the code-action support the server provides. The
      $CodeActionOptions return type is only valid if the client signals code action
      literal support via the property $CodeActionCapabilities.code_action_literal_support.
  - $code_lens_provider: the code-lens support the server provides.
  - $document_formatting_provider: whether the server provides document formatting.
  - $document_range_formatting_provider: whether the server provides document range formatting.
  - $document_on_type_formatting_provider: the document-on-type-formatting options the
    server supports.
  - $rename_provider: the renaming support the server provides.
    RenameOptions may only be specified if the client states that it supports
    $RenameCapabilities.prepare_support in its initial `initialize` request.
  - $document_link_provider: the document-link support the server provides.
  - $color_provider: the color support the server provides.
  - $folding_range_provider: the folding-provider the server supports.
  - $execute_command_provider: the execute-command support the server supports.
  - $workspace: the workspace-specific server capabilities.
  - $experimental: experimental server capabilities.
  */
  constructor
      --text-document-sync       /any                   = null /* TextDocumentSyncOptions | int | Null */
      --hover-provider           /bool?                 = null
      --completion-provider      /CompletionOptions?    = null
      --signature-help-provider  /SignatureHelpOptions? = null
      --definition-provider      /bool?                 = null
      --type-definition-provider /any                   = null /* bool | (TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --implementation-provider  /any                   = null /* bool | (TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --references-provider      /bool?                 = null
      --document-highlight-provider  /bool?             = null
      --document-symbol-provider     /bool?             = null
      --workspace-symbol-provider    /bool?             = null
      --code-action-provider         /any               = null /* bool | CodeActionOptions | Null */
      --code-lens-provider           /CodeLensOptions?  = null
      --document-formatting-provider /bool?             = null
      --document-range-formatting-provider   /bool?     = null
      --document-on-type-formatting-provider /DocumentOnTypeFormattingOptions? = null
      --rename-provider          /any                          = null /* bool | RenameOptions | Null */
      --document-link-provider   /DocumentLinkOptions?         = null
      --color-provider           /any                          = null /* bool | ColorProviderOptions | (ColorProviderOptions & TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --folding-range-provider   /any                          = null /* bool | FoldingRangeProviderOptions | (FoldingRangeProviderOptions & TextDocumentRegistrationOptions & StaticRegistrationOptions) | Null */
      --execute-command-provider /ExecuteCommandOptions?       = null
      --semantic-tokens-provider /SemanticTokensOptions?       = null
      --workspace                /WorkspaceServerCapabilities? = null
      --experimental             /Experimental?                = null:
    map_["textDocumentSync"]       = text-document-sync
    map_["hoverProvider"]          = hover-provider
    map_["completionProvider"]     = completion-provider
    map_["signatureHelpProvider"]  = signature-help-provider
    map_["definitionProvider"]     = definition-provider
    map_["typeDefinitionProvider"] = type-definition-provider
    map_["implementationProvider"] = implementation-provider
    map_["referencesProvider"]     = references-provider
    map_["documentHighlightProvider"]  = document-highlight-provider
    map_["documentSymbolProvider"]     = document-symbol-provider
    map_["workspaceSymbolProvider"]    = workspace-symbol-provider
    map_["codeActionProvider"]         = code-action-provider
    map_["codeLensProvider"]           = code-lens-provider
    map_["documentFormattingProvider"] = document-formatting-provider
    map_["documentRangeFormattingProvider"]  = document-range-formatting-provider
    map_["documentOnTypeFormattingProvider"] = document-on-type-formatting-provider
    map_["renameProvider"]         = rename-provider
    map_["documentLinkProvider"]   = document-link-provider
    map_["colorProvider"]          = color-provider
    map_["foldingRangeProvider"]   = folding-range-provider
    map_["executeCommandProvider"] = execute-command-provider
    map_["semanticTokensProvider"] = semantic-tokens-provider
    map_["workspace"]              = workspace
    map_["experimental"]           = experimental
