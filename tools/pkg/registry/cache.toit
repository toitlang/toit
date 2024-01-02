import .description
import ..file-system-view
import ..semantic-version
import encoding.yaml

/**
A cache of registry descriptions.

This class collects all descriptions in a registry and builds and groups them by url.
*/
class DescriptionUrlCache:
  cache_/Map := {:} // url -> DescriptionVersionCache

  constructor content/FileSystemView:
    recurse_ content

  all-descriptions -> List:
    result := []
    cache_.values.do: | versions/DescriptionVersionCache |
      result.add-all versions.all-descriptions
    return result

  retrieve-description url/string version/SemanticVersion -> Description?:
    version-cache/DescriptionVersionCache? := cache_.get url
    return version-cache and version-cache.get version

  recurse_ content/FileSystemView:
    content.list.do: | name/string entry |
      if entry is FileSystemView:
        recurse_ entry
      else if name == Description.DESCRIPTION-FILE-NAME:
        print "\n$entry:\n$((content.get entry).to-string)"
        description := Description (yaml.decode (content.get entry))
        add_ description

  add_ description/Description:
    (cache_.get description.url --init=(: DescriptionVersionCache)).add_ description

  operator [] url/string -> DescriptionVersionCache?:
    return cache_.get url


/**
A cache of registry descriptions for a url.

This class collects all descriptions for the same url and stores them by version.
*/
class DescriptionVersionCache:
  cache_/Map := {:} // version -> description

  constructor:

  all-descriptions -> List:
    return cache_.values

  get version/SemanticVersion -> Description?:
    return cache_.get version

  add_ description/Description:
    cache_[description.version] = description