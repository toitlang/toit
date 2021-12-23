// Copyright (C) 2019 Toitware ApS. All rights reserved.

import ..rpc
import .document

class DiagnosticSeverity:
  static error       ::= 1
  static warning     ::= 2
  static information ::= 3
  static hint        ::= 4

/**
A diagnostic, such as a compiler error or warning.
*/
class Diagnostic extends MapWrapper:

  related_information= new_value/List/*<DiagnosticRelatedInformation>*/:
    return map_["relatedInformation"] = new_value
  /**
  Creates a diagnostic object.

  Parameters:
  - [range]: the range at which the message applies.
  - [message]: the diagnostic's message.
  - [severity]: the diagnostic's severity. Can be omitted. If omitted it is up to the
                client to interpret diagnostics as error, warning, info or hint.
  - [code]: the diagnostic's code, which might appear in the user interface.
  - [source]: a human-readable string describing the source of this diagnostic,
              e.g. 'typescript' or 'super lint'.
  - [related_information]: an array of related diagnostic information, e.g. when
          symbol-names within a scope collide all definitions can be marked via this property.
  */
  constructor
      --range    /Range
      --message  /string
      --severity /int?    = null  // Of type [DiagnosticSeverity].
      --code     /any     = null
      --source   /string? = null
      --related_information /List?/*<DiagnosticRelatedInformation>*/ = null:
    map_["range"]    = range
    map_["message"]  = message
    map_["severity"] = severity
    map_["code"]     = code
    map_["source"]   = source
    map_["relatedInformation"] = related_information

class DiagnosticRelatedInformation extends MapWrapper:
  location -> Location:
    return at_ "location": Location.from_map it

  message -> string:
    return at_ "message"

  /**
  Creates a related-information-diagnostic object.

  Parameters:
  - [location]: the location of this related diagnostic information.
  - [message]: the message of this related diagnostic information.
  */
  constructor
      --location /Location
      --message  /string:
    map_["location"] = location.map_
    map_["message"]  = message

class PushDiagnosticsParams extends MapWrapper:
  uri -> string: return map_["uri"]

  /**
  Creates a push-diagnostic object, ready to be sent to the client.

  Parameters:
  - [uri]: the URI for which diagnostic information is reported.
  - [diagnostics]: an array of diagnostic information items.
  */
  constructor
      --uri         /string // A DocumentUri.
      --diagnostics /List/*<Diagnostic>*/:
    map_["uri"]         = uri
    map_["diagnostics"] = diagnostics
