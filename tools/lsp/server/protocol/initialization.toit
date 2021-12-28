// Copyright (C) 2019 Toitware ApS. All rights reserved.

import ..rpc
import .experimental

class WorkspaceEditCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The client supports versioned document changes in `WorkspaceEdit`s
  */
  document_changes -> bool?:
    return lookup_ "documentChanges"

  /**
  The resource operations the client supports. Clients should at least
    support 'create', 'rename' and 'delete' files and folders.
  */
  // TODO(florian): should we make an enum for ResourceOperationKind ?
  resource_operations -> List/*<string>*/:
    return lookup_ "resourceOperations"

  /**
  The failure handling strategy of a client if applying the workspace edit fails.
  */
  // TODO(florian): should we have a FailureHandlingKind enum?
  failure_handling -> string?:
    return lookup_ "failureHandling"

/**
A capability for dynamic registration.

This capability should be used as super class.
*/
class DynamicRegistrationCapability extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  Whether a dynamic registration is supported.
  */
  dynamic_registration -> bool:
    return lookup_ "dynamicRegistration"

class DidChangeConfigurationCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class DidChangeWatchedFilesCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class SymbolKindCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The symbol kind values the client supports. When this
    property exists the client also guarantees that it will
    handle values outside its set gracefully and falls back
    to a default value when unknown.

  If this property is not present the client only supports
    the symbol kinds from `File` to `Array` as defined in
    the initial version of the protocol.
  */
  value_set -> List?/*<string>*/:
    // TODO(florian) should we create an enum for the SymbolKinds?
    return lookup_ "valueSet"

class SymbolCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map
  /**
  Specific capabilities for the `SymbolKind` in the `workspace/symbol` request.
  */
  symbol_kind -> SymbolKindCapabilities?:
    return lookup_ "symbolKind": SymbolKindCapabilities it

class ExecuteCommandCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class WorkspaceClientCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The client supports applying batch edits to the workspace by supporting
    the request 'workspace/applyEdit'
  */
  apply_edit -> bool?:
    return lookup_ "applyEdit"

  /**
  Capabilities specific to `WorkspaceEdit`s
  */
  workspace_edit -> WorkspaceEditCapabilities?:
    return lookup_ "workspaceEdit": WorkspaceEditCapabilities it

  /**
  Capabilities specific to the `workspace/didChangeConfiguration` notification.
  */
  did_change_configuration -> DidChangeConfigurationCapabilities?:
    return lookup_ "didChangeConfiguration": DidChangeConfigurationCapabilities it

  /**
  Capabilities specific to the `workspace/didChangeWatchedFiles` notification.
  */
  did_change_watched_files -> DidChangeWatchedFilesCapabilities?:
    return lookup_ "didChangeConfiguration": DidChangeWatchedFilesCapabilities it

  /**
  Capabilities specific to the `workspace/symbol` request.
  */
  symbol -> SymbolCapabilities?:
    return lookup_ "symbol": SymbolCapabilities it

  /**
  Capabilities specific to the `workspace/executeCommand` request.
  */
  execute_command -> ExecuteCommandCapabilities?:
    return lookup_ "executeCommand": ExecuteCommandCapabilities it

  /**
  The client has support for workspace folders.
  */
  workspace_folders -> bool?:
    return lookup_ "workspaceFolders"

  /**
  The client supports `workspace/configuration` requests.
  */
  configuration -> bool?:
    return lookup_ "configuration"

class SynchronizationCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  Whether the client supports sending will save notifications.
  */
  will_save -> bool?: return lookup_ "willSave"

  /**
  The client supports sending a will save request and
    waits for a response providing text edits which will
    be applied to the document before it is saved.
  */
  will_save_wait_until -> bool?: return lookup_ "willSaveWaitUntil"

  /**
  Whether the client supports did save notifications.
  */
  did_save -> bool?: return lookup_ "didSave"

class CompletionItemCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map
  /**
  Whether the client supports snippets as insert text.

  A snippet can define tab stops and placeholders with `$1`, `$2`
    and `${3:foo}`. `$0` defines the final tab stop, it defaults to
    the end of the snippet. Placeholders with equal identifiers are linked,
    that is typing in one will update others too.
  */
  snippet_support -> bool?:
    return lookup_ "snippetSupport"

  /**
  Whether the client supports commit characters on a completion item.
  */
  commit_characters_support -> bool?:
    return lookup_ "commitCharactersSupport"

  /**
  The content formats for the document property the client supports.

  The order describes the preferred format of the client.
  */
  // TODO(florian): this should be an enum.
  documentation_format -> List?/*<string>*/:
    return lookup_ "documentationFormat"

  /**
  Whether the client supports the deprecated property on a completion item.
  */
  deprecated_support -> bool?:
    return lookup_ "deprecatedSupport"

  /**
  Whether the client supports the preselect property on a completion item.
  */
  preselect_support -> bool?:
    return lookup_ "preselectSupport"

// TODO(florian): this should be an enum.
class CompletionItemKind:
  static text           ::= 1
  static method         ::= 2
  static function       ::= 3
  static konstructor    ::= 4
  static field          ::= 5
  static variable       ::= 6
  static klass          ::= 7
  static interface      ::= 8
  static module         ::= 9
  static property       ::= 10
  static unit           ::= 11
  static value          ::= 12
  static enum           ::= 13
  static keyword        ::= 14
  static snippet        ::= 15
  static color          ::= 16
  static file           ::= 17
  static reference      ::= 18
  static folder         ::= 19
  static enum_member    ::= 20
  static constant       ::= 21
  static struct         ::= 22
  static event          ::= 23
  static operator_      ::= 24
  static type_parameter ::= 25

class CompletionItemKindCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map
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
  value_set -> List?/*<int>*/:
    return lookup_ "valueSet"

class CompletionCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  The client supports the following `CompletionItem` specific capabilities.
  */
  completion_item -> CompletionItemCapabilities?:
    return lookup_ "completionItem": CompletionItemCapabilities it

  completion_item_kind -> CompletionItemKindCapabilities?:
    return lookup_ "completionItemKind": CompletionItemKindCapabilities it

  /**
  Whether the client supports to send additional context information for a
    `textDocument/completion` request.
  */
  context_support -> bool?:
    return lookup_ "contextSupport"

class HoverCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  The formats for the content property the client supports.

  The order describes the preferred format of the client.
  */
  // TODO(florian) this should use an enum.
  content_format -> List?/*<string>*/:
    return lookup_ "contentFormat"

class ParameterInformationCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  Whether the client supports processing label offsets instead of a
    simple label string.
  */
  label_offset_support -> bool?:
    return lookup_ "labelOffsetSupport"

class SignatureInformationCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map
  /**
  The content formats for the documentation property the client supports.

  The order describes the preferred format of the client.
  */
  // TODO(florian): this should be an enum. (MarkupKind)
  documentation_format -> List?/*<string>*/:
    return lookup_ "documentationFormat"

  /**
  Client capabilities specific to parameter information.
  */
  parameter_information -> ParameterInformationCapabilities?:
    return lookup_ "parameterInformation": ParameterInformationCapabilities it

class SignatureHelpCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  signature_information -> SignatureInformationCapabilities?:
    return lookup_ "signatureInformation": SignatureInformationCapabilities it

class ReferencesCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class DocumentHighlightCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class DocumentSymbolCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map
  /**
  Specific capabilities for the `SymbolKind`.
  */
  symbol_kind -> SymbolKindCapabilities?:
    return lookup_ "symbolKind": SymbolKindCapabilities it

  /**
  Whether the client supports hierarchical document symbols.
  */
  hierarchical_document_symbol_support -> bool:
    return lookup_ "hierarchicalDocumentSymbolSupport"

class FormattingCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class RangeFormattingCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class OnTypeFormattingCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class DeclarationCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  Whether the client supports additional metadata in the form of declaration links.
  */
  link_support -> bool?:
    return lookup_ "linkSupport"

class DefinitionCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  Whether the client supports additional metadata in the form of definition links.
  */
  link_support -> bool?:
    return lookup_ "linkSupport"

class TypeDefinitionCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  Whether the client supports additional metadata in the form of definition links.
  */
  link_support -> bool?:
    return lookup_ "linkSupport"

class ImplementationCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  Whether the client supports additional metadata in the form of definition links.
  */
  link_support -> bool?:
    return lookup_ "linkSupport"

class CodeActionKindCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The code action kind values the client supports.

  When thisproperty exists the client also guarantees that it will
    handle values outside its set gracefully and falls back
    to a default value when unknown.
  */
  // TODO(florian): CodeActionKind should be an enum.
  value_set -> List?/*<string>*/:
    return lookup_ "valueSet"

class CodeActionLiteralSupportCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The code action kind is support with the following value set.
  */
  code_action_kind -> CodeActionKindCapabilities:
    return lookup_ "codeActionKind": CodeActionKindCapabilities it

class CodeActionCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  The client support code action literals as a valid
    response of the `textDocument/codeAction` request.
  */
  code_action_literal_support -> CodeActionLiteralSupportCapabilities?:
    return lookup_ "codeActionLiteralSupport": CodeActionLiteralSupportCapabilities it

class CodeLensCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class DocumentLinkCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class ColorProviderCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

class RenameCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  The client supports testing for validity of rename operations before execution.
  */
  prepare_support -> bool?:
    return lookup_ "prepareSupport"

class PublishDiagnosticsCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  Whether the clients accepts diagnostics with related information.
  */
  related_information -> bool?:
    return lookup_ "relatedInformation"

class FoldingRangeCapabilities extends DynamicRegistrationCapability:
  constructor json_map/Map: super json_map

  /**
  The maximum number of folding ranges that the client prefers to receive per document. The value serves as a
    hint, servers are free to follow the limit.
  */
  range_limit -> num?:
    return lookup_ "rangeLimit"

  /**
  If set, the client signals that it only supports folding complete lines. If set, client will
    ignore specified `startCharacter` and `endCharacter` properties in a FoldingRange.
  */
  line_folding_only -> bool?:
    return lookup_ "lineFoldingOnly"

class TextDocumentClientCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

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
  signature_help -> SignatureHelpCapabilities?:
    return lookup_ "signatureHelp": SignatureHelpCapabilities it

  /**
  Capabilities specific to the `textDocument/references`
  */
  references -> ReferencesCapabilities?:
    return lookup_ "references": ReferencesCapabilities it

  /**
  Capabilities specific to the `textDocument/documentHighlight`
  */
  document_highlight -> DocumentHighlightCapabilities?:
    return lookup_ "documentHighlight": DocumentHighlightCapabilities it

  /**
  Capabilities specific to the `textDocument/documentSymbol`
  */
  document_symbol -> DocumentSymbolCapabilities?:
    return lookup_ "documentSymbol": DocumentSymbolCapabilities it

  /**
  Capabilities specific to the `textDocument/formatting`
  */
  formatting -> FormattingCapabilities?:
    return lookup_ "formatting": FormattingCapabilities it

  /**
   * Capabilities specific to the `textDocument/rangeFormatting`
   */
  range_formatting -> RangeFormattingCapabilities?:
    return lookup_ "rangeFormatting": RangeFormattingCapabilities it

  /**
   * Capabilities specific to the `textDocument/onTypeFormatting`
   */
  on_type_formatting -> OnTypeFormattingCapabilities?:
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
  type_definition -> TypeDefinitionCapabilities?:
    return lookup_ "typeDefinition": TypeDefinitionCapabilities it

  /**
  Capabilities specific to the `textDocument/implementation`.
  */
  implementation -> ImplementationCapabilities?:
    return lookup_ "implementation": ImplementationCapabilities it

  /**
  Capabilities specific to the `textDocument/codeAction`
  */
  code_action -> CodeActionCapabilities?:
    return lookup_ "codeAction": CodeActionCapabilities it

  /**
  Capabilities specific to the `textDocument/codeLens`
  */
  code_lens -> CodeLensCapabilities?:
    return lookup_ "codeLens": CodeLensCapabilities it

  /**
  Capabilities specific to the `textDocument/documentLink`
  */
  document_link -> DocumentLinkCapabilities?:
    return lookup_ "documentLink": DocumentLinkCapabilities it

  /**
  Capabilities specific to the `textDocument/documentColor` and the
    `textDocument/colorPresentation` request.
  */
  color_provider -> ColorProviderCapabilities?:
    return lookup_ "colorProvider": ColorProviderCapabilities it

  /**
  Capabilities specific to the `textDocument/rename`
  */
  rename -> RenameCapabilities?:
    return lookup_ "rename": RenameCapabilities it

  /**
  Capabilities specific to `textDocument/publishDiagnostics`.
  */
  publish_diagnostics -> PublishDiagnosticsCapabilities?:
    return lookup_ "publishDiagnostics": PublishDiagnosticsCapabilities it

  /**
  Capabilities specific to `textDocument/foldingRange` requests.
  */
  folding_range -> FoldingRangeCapabilities?:
    return lookup_ "foldingRange": FoldingRangeCapabilities it


class ClientCapabilities extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  Workspace specific client capabilities.
  */
  workspace -> WorkspaceClientCapabilities?:
    return lookup_ "workspace": WorkspaceClientCapabilities it

  /**
  Text document specific client capabilities.
  */
  text_document -> TextDocumentClientCapabilities?:
    return lookup_ "textDocument": TextDocumentClientCapabilities it

  /**
  Experimental client capabilities.
  */
  experimental -> Experimental?:
    return lookup_ "experimental": Experimental it

class InitializeParams extends MapWrapper:
  constructor json_map/Map: super json_map

  /**
  The process Id of the parent process that started the server.

  Is null if the process has not been started by another process.
  If the parent process is not alive then the server should exit (see exit notification) its process.
  */
  process_id -> int?:
    return lookup_ "processId"

  /**
  The rootUri of the workspace.

  Is null if no folder is open.
  */
  // TODO(florian): should we handle the URI different from a string?
  root_uri -> string?:
    return lookup_ "rootUri"

  /**
  User provided initialization options.
  */
  initialization_options -> any:
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
  workspace_folders -> List?/*<WorkspaceFolder>*/:
    return null
