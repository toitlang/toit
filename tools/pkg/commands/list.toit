import system

import cli
import encoding.json
import encoding.yaml

import ..pkg
import ..registry
import ..error

class ListCommand:
  name/string?
  verbose/bool
  output/string

  constructor parsed/cli.Parsed:
    name = parsed[NAME-OPTION]
    verbose = parsed[VERBOSE-OPTION]
    output = parsed[OUTPUT-OPTION]

  execute:
    registry-packages := registries.list-packages
    //  the packages list in each registry has this format [ package-name, version-name, description ]
    if name:
      if not registry-packages.contains name:
        error "Registry not found: $name"
      registry-packages.filter --in-place: | k v | k == name

    if output == "list":
      registry-packages.do: | registry-name registry/Map |
        print "$registry-name: $(registry["registry"].stringify)"
        list-textual registry["packages"] --verbose=verbose --indent="  "
    else:
      result/Map := ?
      if verbose:
        result = registry-packages.map: | registry-name registry/Map |
          { "registry": registry["registry"].to-map,
            "packages": (registry["packages"].map: verbose-description it[2])
          }
      else:
        result = registry-packages.map: | registry-name registry/Map |
          { "registry": registry["registry"].stringify,
            "packages": (registry["packages"].map: {
              it[0] : it[1]
            })
          }
      if output == "json":
        print (json.stringify result)
      else if output == "yaml":
        print (yaml.stringify result)

  static verbose-description description/Map --allow-extra-fields=false -> Map:
    result := {:}
    result[description["name"]] = description.filter: | k _ |
      k != Description.NAME-KEY_ and
           (allow-extra-fields or
            k != Description.DEPENDENCIES-KEY_ and k != Description.ENVIRONMENT-KEY_)
    return result

  static list-textual packages/List --verbose/bool --indent/string="":
    packages.do:
      if verbose:
        description := (yaml.stringify (verbose-description it[2]))
        print "$indent$((description.split "\n").join "\n$indent")"
      else:
        print "$indent$it[0] - $it[1]"


  static CLI-COMMAND ::=
      cli.Command "list"
          --help="""
                 Lists all packages.

                 If no argument is given, lists all available packages.
                 If an argument is given, it must point to a registry path. In that case
                   only the packages from that registry are shown.
                 """
          --rest=[
              cli.Option NAME-OPTION
                  --required=false
            ]
          --options=[
              cli.Flag VERBOSE-OPTION
                  --short-name="v"
                  --help="Show more information about each package."
                  --default=false,
              cli.OptionEnum OUTPUT-OPTION ["list", "json", "yaml"]
                  --short-name="o"
                  --help="Output format."
                  --default="list"
            ]
          --run=:: (ListCommand it).execute

  static NAME-OPTION ::= "name"
  static VERBOSE-OPTION ::= "verbose"
  static OUTPUT-OPTION ::= "output"