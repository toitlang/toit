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
import .completion show CompletionList // For Toitdoc.

class WorkspaceEditCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  The client supports versioned document changes in `WorkspaceEdit`s
  */
  document-changes -> bool?:
    return lookup_ "documentChanges"

  /**
  The resource operations the client supports. Clients should at least
    support 'create', 'rename' and 'delete' files and folders.
  */
  // TODO(florian): should we make an enum for ResourceOperationKind ?
  resource-operations -> List/*<string>*/:
    return lookup_ "resourceOperations"

  /**
  The failure handling strategy of a client if applying the workspace edit fails.
  */
  // TODO(florian): should we have a FailureHandlingKind enum?
  failure-handling -> string?:
    return lookup_ "failureHandling"

/**
A capability for dynamic registration.

This capability should be used as super class.
*/
class DynamicRegistrationCapability extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  Whether a dynamic registration is supported.
  */
  dynamic-registration -> bool:
    return lookup_ "dynamicRegistration"

class DidChangeConfigurationCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class DidChangeWatchedFilesCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class SymbolKindCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  The symbol kind values the client supports. When this
    property exists the client also guarantees that it will
    handle values outside its set gracefully and falls back
    to a default value when unknown.

  If this property is not present the client only supports
    the symbol kinds from `File` to `Array` as defined in
    the initial version of the protocol.
  */
  value-set -> List?/*<string>*/:
    // TODO(florian) should we create an enum for the SymbolKinds?
    return lookup_ "valueSet"

class SymbolCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map
  /**
  Specific capabilities for the `SymbolKind` in the `workspace/symbol` request.
  */
  symbol-kind -> SymbolKindCapabilities?:
    return lookup_ "symbolKind": SymbolKindCapabilities it

class ExecuteCommandCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class WorkspaceClientCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  The client supports applying batch edits to the workspace by supporting
    the request 'workspace/applyEdit'
  */
  apply-edit -> bool?:
    return lookup_ "applyEdit"

  /**
  Capabilities specific to `WorkspaceEdit`s
  */
  workspace-edit -> WorkspaceEditCapabilities?:
    return lookup_ "workspaceEdit": WorkspaceEditCapabilities it

  /**
  Capabilities specific to the `workspace/didChangeConfiguration` notification.
  */
  did-change-configuration -> DidChangeConfigurationCapabilities?:
    return lookup_ "didChangeConfiguration": DidChangeConfigurationCapabilities it

  /**
  Capabilities specific to the `workspace/didChangeWatchedFiles` notification.
  */
  did-change-watched-files -> DidChangeWatchedFilesCapabilities?:
    return lookup_ "didChangeConfiguration": DidChangeWatchedFilesCapabilities it

  /**
  Capabilities specific to the `workspace/symbol` request.
  */
  symbol -> SymbolCapabilities?:
    return lookup_ "symbol": SymbolCapabilities it

  /**
  Capabilities specific to the `workspace/executeCommand` request.
  */
  execute-command -> ExecuteCommandCapabilities?:
    return lookup_ "executeCommand": ExecuteCommandCapabilities it

  /**
  The client has support for workspace folders.
  */
  workspace-folders -> bool?:
    return lookup_ "workspaceFolders"

  /**
  The client supports `workspace/configuration` requests.
  */
  configuration -> bool?:
    return lookup_ "configuration"

class SynchronizationCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  Whether the client supports sending will save notifications.
  */
  will-save -> bool?: return lookup_ "willSave"

  /**
  The client supports sending a will save request and
    waits for a response providing text edits which will
    be applied to the document before it is saved.
  */
  will-save-wait-until -> bool?: return lookup_ "willSaveWaitUntil"

  /**
  Whether the client supports did save notifications.
  */
  did-save -> bool?: return lookup_ "didSave"

class CompletionItemCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map
  /**
  Whether the client supports snippets as insert text.

  A snippet can define tab stops and placeholders with `$1`, `$2`
    and `${3:foo}`. `$0` defines the final tab stop, it defaults to
    the end of the snippet. Placeholders with equal identifiers are linked,
    that is typing in one will update others too.
  */
  snippet-support -> bool?:
    return lookup_ "snippetSupport"

  /**
  Whether the client supports commit characters on a completion item.
  */
  commit-characters-support -> bool?:
    return lookup_ "commitCharactersSupport"

  /**
  The content formats for the document property the client supports.

  The order describes the preferred format of the client.
  */
  // TODO(florian): this should be an enum.
  documentation-format -> List?/*<string>*/:
    return lookup_ "documentationFormat"

  /**
  Whether the client supports the deprecated property on a completion item.
  */
  deprecated-support -> bool?:
    return lookup_ "deprecatedSupport"

  /**
  Whether the client supports the preselect property on a completion item.
  */
  preselect-support -> bool?:
    return lookup_ "preselectSupport"

// TODO(florian): this should be an enum.
class CompletionItemKind:
  static TEXT           ::= 1
  static METHOD         ::= 2
  static FUNCTION       ::= 3
  static CONSTRUCTOR    ::= 4
  static FIELD          ::= 5
  static VARIABLE       ::= 6
  static CLASS          ::= 7
  static INTERFACE      ::= 8
  static MODULE         ::= 9
  static PROPERTY       ::= 10
  static UNIT           ::= 11
  static VALUE          ::= 12
  static ENUM           ::= 13
  static KEYWORD        ::= 14
  static SNIPPET        ::= 15
  static COLOR          ::= 16
  static FILE           ::= 17
  static REFERENCE      ::= 18
  static FOLDER         ::= 19
  static ENUM-MEMBER    ::= 20
  static CONSTANT       ::= 21
  static STRUCT         ::= 22
  static EVENT          ::= 23
  static OPERATOR       ::= 24
  static TYPE-PARAMETER ::= 25

class CompletionItemKindCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map
  /**
  The completion item kind values the client supports. When this
    property exists the client also guarantees that it will
    handle values outside its set gracefully and falls back
    to a default value when unknown.

  If this property is not present the client only supports
    the completion items kinds from `Text` to `Reference` as defined in
    the initial version of the protocol.
  */
  // TODO(florian): should this be a CompletionItemKind enum ?
  value-set -> List?/*<int>*/:
    return lookup_ "valueSet"

class CompletionListCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  The list of item-defaults the client supports in the
    $CompletionList'.item-defaults' object.

  In null, then no properties are supported.
  */
  item-defaults -> List?:
    return lookup_ "itemDefaults"


class CompletionCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  The client supports the following `CompletionItem` specific capabilities.
  */
  completion-item -> CompletionItemCapabilities?:
    return lookup_ "completionItem": CompletionItemCapabilities it

  completion-item-kind -> CompletionItemKindCapabilities?:
    return lookup_ "completionItemKind": CompletionItemKindCapabilities it

  /**
  Whether the client supports to send additional context information for a
    `textDocument/completion` request.
  */
  context-support -> bool?:
    return lookup_ "contextSupport"

  completion-list -> CompletionListCapabilities?:
    return lookup_ "completionList": CompletionListCapabilities it

class HoverCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  The formats for the content property the client supports.

  The order describes the preferred format of the client.
  */
  // TODO(florian) this should use an enum.
  content-format -> List?/*<string>*/:
    return lookup_ "contentFormat"

class ParameterInformationCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  Whether the client supports processing label offsets instead of a
    simple label string.
  */
  label-offset-support -> bool?:
    return lookup_ "labelOffsetSupport"

class SignatureInformationCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map
  /**
  The content formats for the documentation property the client supports.

  The order describes the preferred format of the client.
  */
  // TODO(florian): this should be an enum. (MarkupKind)
  documentation-format -> List?/*<string>*/:
    return lookup_ "documentationFormat"

  /**
  Client capabilities specific to parameter information.
  */
  parameter-information -> ParameterInformationCapabilities?:
    return lookup_ "parameterInformation": ParameterInformationCapabilities it

class SignatureHelpCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  signature-information -> SignatureInformationCapabilities?:
    return lookup_ "signatureInformation": SignatureInformationCapabilities it

class ReferencesCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class DocumentHighlightCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class DocumentSymbolCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map
  /**
  Specific capabilities for the `SymbolKind`.
  */
  symbol-kind -> SymbolKindCapabilities?:
    return lookup_ "symbolKind": SymbolKindCapabilities it

  /**
  Whether the client supports hierarchical document symbols.
  */
  hierarchical-document-symbol-support -> bool:
    return lookup_ "hierarchicalDocumentSymbolSupport"

class FormattingCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class RangeFormattingCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class OnTypeFormattingCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class DeclarationCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  Whether the client supports additional metadata in the form of declaration links.
  */
  link-support -> bool?:
    return lookup_ "linkSupport"

class DefinitionCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  Whether the client supports additional metadata in the form of definition links.
  */
  link-support -> bool?:
    return lookup_ "linkSupport"

class TypeDefinitionCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  Whether the client supports additional metadata in the form of definition links.
  */
  link-support -> bool?:
    return lookup_ "linkSupport"

class ImplementationCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  Whether the client supports additional metadata in the form of definition links.
  */
  link-support -> bool?:
    return lookup_ "linkSupport"

class CodeActionKindCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  The code action kind values the client supports.

  When thisproperty exists the client also guarantees that it will
    handle values outside its set gracefully and falls back
    to a default value when unknown.
  */
  // TODO(florian): CodeActionKind should be an enum.
  value-set -> List?/*<string>*/:
    return lookup_ "valueSet"

class CodeActionLiteralSupportCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  The code action kind is support with the following value set.
  */
  code-action-kind -> CodeActionKindCapabilities:
    return lookup_ "codeActionKind": CodeActionKindCapabilities it

class CodeActionCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  The client support code action literals as a valid
    response of the `textDocument/codeAction` request.
  */
  code-action-literal-support -> CodeActionLiteralSupportCapabilities?:
    return lookup_ "codeActionLiteralSupport": CodeActionLiteralSupportCapabilities it

class CodeLensCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class DocumentLinkCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class ColorProviderCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

class RenameCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  The client supports testing for validity of rename operations before execution.
  */
  prepare-support -> bool?:
    return lookup_ "prepareSupport"

class PublishDiagnosticsCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  /**
  Whether the clients accepts diagnostics with related information.
  */
  related-information -> bool?:
    return lookup_ "relatedInformation"

class FoldingRangeCapabilities extends DynamicRegistrationCapability:
  constructor json-map/Map: super json-map

  /**
  The maximum number of folding ranges that the client prefers to receive per document. The value serves as a
    hint, servers are free to follow the limit.
  */
  range-limit -> num?:
    return lookup_ "rangeLimit"

  /**
  If set, the client signals that it only supports folding complete lines. If set, client will
    ignore specified `startCharacter` and `endCharacter` properties in a FoldingRange.
  */
  line-folding-only -> bool?:
    return lookup_ "lineFoldingOnly"

class TextDocumentClientCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  synchronization -> SynchronizationCapabilities?:
    return lookup_ "synchronization": SynchronizationCapabilities it

  /**
  Capabilities specific to the `textDocument/completion`
  */
  completion -> CompletionCapabilities?:
    return lookup_ "completion": CompletionCapabilities it

  /**
  Capabilities specific to the `textDocument/hover`
  */
  hover -> HoverCapabilities?:
    return lookup_ "hover": HoverCapabilities it

  /**
  Capabilities specific to the `textDocument/signatureHelp`
  */
  signature-help -> SignatureHelpCapabilities?:
    return lookup_ "signatureHelp": SignatureHelpCapabilities it

  /**
  Capabilities specific to the `textDocument/references`
  */
  references -> ReferencesCapabilities?:
    return lookup_ "references": ReferencesCapabilities it

  /**
  Capabilities specific to the `textDocument/documentHighlight`
  */
  document-highlight -> DocumentHighlightCapabilities?:
    return lookup_ "documentHighlight": DocumentHighlightCapabilities it

  /**
  Capabilities specific to the `textDocument/documentSymbol`
  */
  document-symbol -> DocumentSymbolCapabilities?:
    return lookup_ "documentSymbol": DocumentSymbolCapabilities it

  /**
  Capabilities specific to the `textDocument/formatting`
  */
  formatting -> FormattingCapabilities?:
    return lookup_ "formatting": FormattingCapabilities it

  /**
   * Capabilities specific to the `textDocument/rangeFormatting`
   */
  range-formatting -> RangeFormattingCapabilities?:
    return lookup_ "rangeFormatting": RangeFormattingCapabilities it

  /**
   * Capabilities specific to the `textDocument/onTypeFormatting`
   */
  on-type-formatting -> OnTypeFormattingCapabilities?:
    return lookup_ "onTypeFormatting": OnTypeFormattingCapabilities it

  /**
  Capabilities specific to the `textDocument/declaration`
  */
  declaration -> DeclarationCapabilities?:
    return lookup_ "declaration": DeclarationCapabilities it

  /**
  Capabilities specific to the `textDocument/definition`.
  */
  definition -> DefinitionCapabilities?:
    return lookup_ "definition": DefinitionCapabilities it

  /**
  Capabilities specific to the `textDocument/typeDefinition`
  */
  type-definition -> TypeDefinitionCapabilities?:
    return lookup_ "typeDefinition": TypeDefinitionCapabilities it

  /**
  Capabilities specific to the `textDocument/implementation`.
  */
  implementation -> ImplementationCapabilities?:
    return lookup_ "implementation": ImplementationCapabilities it

  /**
  Capabilities specific to the `textDocument/codeAction`
  */
  code-action -> CodeActionCapabilities?:
    return lookup_ "codeAction": CodeActionCapabilities it

  /**
  Capabilities specific to the `textDocument/codeLens`
  */
  code-lens -> CodeLensCapabilities?:
    return lookup_ "codeLens": CodeLensCapabilities it

  /**
  Capabilities specific to the `textDocument/documentLink`
  */
  document-link -> DocumentLinkCapabilities?:
    return lookup_ "documentLink": DocumentLinkCapabilities it

  /**
  Capabilities specific to the `textDocument/documentColor` and the
    `textDocument/colorPresentation` request.
  */
  color-provider -> ColorProviderCapabilities?:
    return lookup_ "colorProvider": ColorProviderCapabilities it

  /**
  Capabilities specific to the `textDocument/rename`
  */
  rename -> RenameCapabilities?:
    return lookup_ "rename": RenameCapabilities it

  /**
  Capabilities specific to `textDocument/publishDiagnostics`.
  */
  publish-diagnostics -> PublishDiagnosticsCapabilities?:
    return lookup_ "publishDiagnostics": PublishDiagnosticsCapabilities it

  /**
  Capabilities specific to `textDocument/foldingRange` requests.
  */
  folding-range -> FoldingRangeCapabilities?:
    return lookup_ "foldingRange": FoldingRangeCapabilities it


class ClientCapabilities extends MapWrapper:
  constructor json-map/Map: super json-map

  constructor
      --workspace / WorkspaceClientCapabilities? = null
      --text-document / TextDocumentClientCapabilities? = null
      --experimental / Experimental? = null:
    if workspace: map_["workspace"] = workspace.map_
    if text-document: map_["textDocument"] = text-document.map_
    if experimental: map_["experimental"] = experimental.map_

  /**
  Workspace specific client capabilities.
  */
  workspace -> WorkspaceClientCapabilities?:
    return lookup_ "workspace": WorkspaceClientCapabilities it

  /**
  Text document specific client capabilities.
  */
  text-document -> TextDocumentClientCapabilities?:
    return lookup_ "textDocument": TextDocumentClientCapabilities it

  /**
  Experimental client capabilities.
  */
  experimental -> Experimental?:
    return lookup_ "experimental": Experimental it

class InitializeParams extends MapWrapper:
  constructor json-map/Map: super json-map

  constructor
      --process-id / int? = null
      --root-uri / string? = null
      --initialization-options / any = null
      --capabilities / ClientCapabilities
      --trace / string? = null
      --workspace-folders / List?/*<WorkspaceFolder>*/ = null:
    if process-id: map_["processId"] = process-id
    if root-uri: map_["rootUri"] = root-uri
    if initialization-options != null: map_["initializationOptions"] = initialization-options
    map_["capabilities"] = capabilities.map_
    if trace: map_["trace"] = trace
    if workspace-folders: map_["workspaceFolders"] = workspace-folders


  /**
  The process Id of the parent process that started the server.

  Is null if the process has not been started by another process.
  If the parent process is not alive then the server should exit (see exit notification) its process.
  */
  process-id -> int?:
    return lookup_ "processId"

  /**
  The rootUri of the workspace.

  Is null if no folder is open.
  */
  // TODO(florian): should we handle the URI different from a string?
  root-uri -> string?:
    return lookup_ "rootUri"

  /**
  User provided initialization options.
  */
  initialization-options -> any:
    return lookup_ "initializationOptions"

  /**
  The capabilities provided by the client (editor or tool)
  */
  capabilities -> ClientCapabilities:
    return lookup_ "capabilities": ClientCapabilities it

  /**
  The initial trace setting. If omitted trace is disabled ('off').
  */
  // TODO(florian): should we have a TraceSetting enum?
  trace -> string?:
    return lookup_ "trace"

  /**
  The workspace folders configured in the client when the server starts.

  This property is only available if the client supports workspace folders.
  It can be `null` if the client supports workspace folders but none are configured.
  */
  // TODO(florian): handle workspace_folders
  workspace-folders -> List?/*<WorkspaceFolder>*/:
    return null
