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

import cli

import ..semantic-version
import ..constraints
import ..project.specification show PackageDependency

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

  static DESCRIPTION-FILE-NAME ::= "desc.yaml"

  content/Map

  cached-version_/SemanticVersion? := null
  cached-sdk-version_/List := []
  cached-dependencies_/List? := null

  /**
  Constructs a description from the given content.

  The $path is only used for error messages.
  */
  constructor .content --path/string --ui/cli.Ui:
    if not content.contains NAME-KEY_:
      ui.abort "Description at $path is missing a name."
    if not content.contains URL-KEY_:
      ui.abort "Description at $path is missing a url."
    url := content[URL-KEY_]
    if url is not string:
      ui.abort "Description at $path has an invalid url: $url."
    if url == "":
      ui.abort "Description at $path has an empty url."
    if not content.contains VERSION-KEY_:
      ui.abort "Description at $path is missing a version."
    version := content[VERSION-KEY_]
    e := catch:
      SemanticVersion.parse version
    if e:
      ui.abort "Description at $path has an invalid version: '$version'."
    if not content.contains HASH-KEY_:
      ui.abort "Description at $path is missing a hash."

  // A constructor that is primarily used for testing.
  constructor.for-testing_
      --name/string
      --url/string
      --description/string=""
      --version/SemanticVersion=(SemanticVersion.parse "v1.0.0")
      --ref-hash/string="deadbeef1234567890abcdef1234567890abcdef"
      --min-sdk/SemanticVersion?=null
      --dependencies/List=[]
      --ui/cli.Ui:
    map := {
      NAME-KEY_: name,
      URL-KEY_: url,
      DESCRIPTION-KEY_: description,
      VERSION-KEY_: version.to-string,
      HASH-KEY_: ref-hash,
      DEPENDENCIES-KEY_: dependencies.map: | dep/PackageDependency |
          {
            URL-KEY_: dep.url,
            VERSION-KEY_: dep.constraint.to-string
          }
    }
    if min-sdk: map[ENVIRONMENT-KEY_] = {SDK-KEY_: "^$min-sdk.to-string"}
    return Description map --path=name --ui=ui

  url -> string: return content[URL-KEY_]

  name -> string: return content[NAME-KEY_]

  ref-hash -> string: return content.get HASH-KEY_

  description -> string: return content[DESCRIPTION-KEY_]

  version -> SemanticVersion:
    if not cached-version_:
      cached-version_ = SemanticVersion.parse content[VERSION-KEY_]
    return cached-version_

  sdk-version -> Constraint?:
    if cached-sdk-version_.is-empty:
      if environment := content.get ENVIRONMENT-KEY_:
        if sdk-constraint := environment.get SDK-KEY_:
          cached-sdk-version_.add (Constraint.parse sdk-constraint)
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
                url := dep[URL-KEY_]
                constraint := Constraint.parse dep[VERSION-KEY_]
                PackageDependency url --constraint=constraint
    return cached-dependencies_

  satisfies-sdk-version concrete-sdk-version/SemanticVersion -> bool:
    return not sdk-version or sdk-version.satisfies concrete-sdk-version

  matches-free-text search-string/string -> bool:
    return url.to-ascii-lower.contains search-string or
        name.to-ascii-lower.contains search-string or
        description.to-ascii-lower.contains search-string

  stringify -> string:
    return "$name ($version) - $description"
