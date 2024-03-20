// Copyright (C) 2024 Toitware ApS.
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

import ..semantic-version
import ..constraints
import ..project.package

class Description:
  static NAME-KEY_         ::= "name"
  static DESCRIPTION-KEY_  ::= "description"
  static LICENSE-KEY_      ::= "license"
  static URL-KEY_          ::= "url"
  static VERSION-KEY_      ::= "version"
  static ENVIRONMENT-KEY_  ::= "environment"
  static HASH-KEY_         ::= "hash"
  static DEPENDENCIES-KEY_ ::= "dependencies"
  static SDK-KEY_          ::= "sdk"

  static DESCRIPTION_FILE_NAME ::= "desc.yaml"

  content/Map

  cached-version_/SemanticVersion? := null
  cached-sdk-version_/List := []
  cached-dependencies_/List? := null

  constructor .content:

  url -> string: return content[URL-KEY_]

  name -> string: return content[NAME-KEY_]

  ref-hash -> string: return content[HASH-KEY_]

  description -> string: return content[DESCRIPTION-KEY_]

  version -> SemanticVersion:
    if not cached_version_:
      cached_version_ = SemanticVersion content[VERSION-KEY_]
    return cached_version_

  sdk-version -> Constraint?:
    if cached-sdk-version_.is-empty:
      if environment := content.get ENVIRONMENT-KEY_:
        if sdk-constraint := environment.get SDK-KEY_:
          cached-sdk-version_.add (Constraint sdk-constraint)
          return cached-sdk-version_[0]
      cached-sdk-version_.add null
    return cached-sdk-version_[0]

  dependencies -> List:
    if not cached-dependencies_:
      if not content.contains DEPENDENCIES-KEY_:
        cached-dependencies_ = []
      else:
        cached-dependencies_ =
            content[DEPENDENCIES-KEY_].map: | dep |
                PackageDependency dep[URL-KEY_] dep[VERSION-KEY_]
    return cached-dependencies_

  satisfies-sdk-version concrete-sdk-version/SemanticVersion -> bool:
    return not sdk-version or sdk-version.satisfies concrete-sdk-version

  matches-free-text search-string/string -> bool:
    return url.to-ascii-lower.contains search-string or
        name.to-ascii-lower.contains search-string or
        description.to-ascii-lower.contains search-string
