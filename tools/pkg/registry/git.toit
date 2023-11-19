import encoding.yaml

import ..git
import ..git.file-system-view
import ..utils
import ..semantic-version
import .registry

class GitRegistry extends Registry:
  type ::= "git"
  url/string
  content_/FileSystemView? := null

  description-cache_ := {:}

  constructor name .url:
    super name

  content -> FileSystemView:
    if not content_: content_ = load_
    return content_

  search search-string/string -> List:
    search-version := null
    if search-string.contains "@":
      split := search-string.split "@"
      search-string = split[0]
      search-version = split[1]

    // name-paths will always have size 4 and be pre- and post-fixed with null for missing search terms.
    // For example "toitlang/pkg-host" will be [null, "toitlang", "pkg-host", null]
    // And "pkg-host@1.7.1" will be [null, null, "pkg-host", "1.7.1"
    name-paths := search-string.split "/"
    paths := []
    (3 - name-paths.size).repeat:
      paths.add null
    paths.add-all name-paths
    paths.add search-version

    packages-files := content.get "packages"

    search-result := prefix-search_ paths packages-files

    packages := []
    search-result.do: | hub-list |
      hub := hub-list[0]
      hub-list[1].do: | repository-list |
        repository := repository-list[0]
        repository-list[1].do: | package-list |
          package := package-list[0]
          packages.add [ [ hub, repository, package ], package-list[1] ]

    packages = packages.map --in-place:
      package := it[0]
      version := reduce-versions_ it[1]
      package-url := package.join "/"
      description := yaml.decode
          packages-files.get
              flatten_list [package, version, "desc.yaml"]
      RemotePackage package-url version description

    return packages

  static prefix-search_ paths/List files/FileSystemView -> List?:
    if paths.is-empty: return []
    if paths[0] == null:
      if paths.size == 1: // Version term
        return files.list.keys
      result := []
      files.list.do: | k v |
        if v is FileSystemView:
          sub-search := prefix-search_ paths[1..] v
          if sub-search:
            result.add [ k, sub-search ]
      return result.is-empty ? null : result
    else:
      sub-structure := files.get paths[0]
      if sub-structure:
        if paths.size == 1:
          return [ paths[0] ]
        else:
          return [[ paths[0], prefix-search_ paths[1..] sub-structure ]]
      return null

  static reduce-versions_ versions/List:
    highest := SemanticVersion versions[0]
    versions[1..].do:
      next := SemanticVersion it
      if highest <= next: highest = next
    return highest.stringify

  load_ -> FileSystemView:
    repository := open-repository url
    head-ref/string := repository.head
    pack := repository.clone head-ref
    return pack.content

  retrieve-description url/string version/SemanticVersion -> Description?:
    if not description-cache_.contains url or not description-cache_[url].contains version:
      url-cache := description-cache_.get url --if-absent=: description-cache_[url] = {:}
      desc-buffer := content.get --path=(flatten_list ["packages", url.split "/", version.stringify, "desc.yaml" ])
      url-cache[version] = desc-buffer and Description (yaml.decode desc-buffer)

    return description-cache_[url][version]

  retrieve-versions url/string -> List?:
    versions := content.get --path=(flatten_list ["packages", url.split "/"])
    if not versions is FileSystemView: return null
    semantic-versions/List := versions.list.keys.map: SemanticVersion it

    // Sort
    semantic-versions.sort --in-place

    // Reverse
    result := []
    semantic-versions.do --reversed: result.add it

    return result

