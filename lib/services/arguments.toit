// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

class ArgumentParser:
  constructor --.rest_minimum/int?=null --.rest_description/string?=null:

  /**
  Add a new command to the parser.
  The optional `rest` argument is a list of strings, each of which describes the
    non-option rest arguments that follow the command.  It is used to check usage
    and provide error messages.
  Returns a new $ArgumentParser for the given command.
  */
  add_command name/string --rest/List?=null -> ArgumentParser:
    // TODO(kasper): Check if we already have a parser for the given
    // command name. Don't allow duplicates.
    minimum := rest ? rest.size : null
    description := rest ? "<$(rest.join "> <")>" : null
    return commands_[name] = ArgumentParser --rest_minimum=minimum --rest_description=description

  /// Adds a boolean flag for the given name. Always defaults to false. Can be
  ///   set to true by passing '--<name>' or '-<short>' if short isn't null.
  add_flag name/string --short/string?=null -> none:
    options_["--$name"] = Option_ name --is_flag --default=false
    if short: add_alias name short

  /// Adds an option with the given default value.
  add_option name/string --default=null --short/string?=null -> none:
    options_["--$name"] = Option_ name --default=default
    if short: add_alias name short

  /// Adds an option that can be provided multiple times.
  add_multi_option name/string --split_commas/bool=true --short/string?=null -> none:
    options_["--$name"] = Option_ name --is_multi_option --split_commas=split_commas
    if short: add_alias name short

  /// Adds a short alias for an option.
  add_alias name/string short/string:
    options_["-$short"] = options_["--$name"]

  /// Parses the given $arguments. Returns a new instance of $Arguments.
  parse arguments --exit_on_error/bool=true -> Arguments:
    try:
      return parse_ this null arguments 0
    finally: | is_exception exception |
      if is_exception:
        print_on_stderr_ "$exception.value"
        print_on_stderr_
            usage arguments
        if exit_on_error:
          exit 1
        throw exception.value

  commands_ := {:}
  options_ := {:}
  rest_description/string?
  rest_minimum/int?

  /// Provides a usage guide for the user.  The arguments list is
  ///   used to limit usage to a subcommand if any.
  usage arguments index/int=0 --invoked_command=program_name -> string:
    result := "Usage:"
    prefix := "toit.run $invoked_command "
    parser := this
    while arguments.size > index:
      command := arguments[index]
      if parser.commands_.contains command:
        prefix += command + " "
        parser = commands_[command]
        index++
      else:
        break
    return "Usage:" + (parser.usage_ --prefix=prefix)

  usage_ --prefix -> string:
    options_.do: | name option |
      if name.starts_with "--":
        display_name := name
        options_.do: | shortname shortoption |
          if shortname != name and shortoption == option:
            display_name = "$display_name|$shortname"
        if option.is_flag:
          prefix = "$(prefix)[$display_name] "
        else:
          star := option.is_multi_option ? "*" : ""
          prefix = "$(prefix)[$display_name=<$name[2..]>]$star "
    if commands_.is_empty:
      if rest_description:
        return "\n$prefix $rest_description"
      return "\n$prefix"
    result := ""
    commands_.do: | command subparser |
      result += subparser.usage_ --prefix="$prefix$command "
    return result

class Arguments:
  constructor .command_:
  constructor .command_ .options_ .rest_:

  /// Returns the parsed command or null.
  command -> string?:
    return command_

  // Returns the parsed option or the default value.
  operator[] key/string -> any:
    return options_.get key --if_absent=: throw "No option named '$key'"

  // Returns the non-option arguments.
  rest -> List:
    return rest_

  stringify:
    buffer := []
    if command_: buffer.add command_
    options_.do: | name value | buffer.add "--$name=$value"
    if not rest_.is_empty:
      buffer.add "--"
      rest_.do: buffer.add it
    return buffer.join " "

  command_ := ?
  options_ := {:}
  rest_ := []

// ----------------------------------------------------------------------------

// Argument parsing functionality.
parse_ grammar command arguments index:
  if not command and index < arguments.size:
    first := arguments[index]
    grammar.commands_.get first --if_present=:
      sub := it
      return parse_ sub first arguments index + 1

  // Populate the options from the default values or empty lists (for multi-options)
  options := {:}
  rest := []
  grammar.options_.do --values:
    if it.is_multi_option:
      options[it.name] = []
    else:
      options[it.name] = it.default

  seen_options := {}

  while index < arguments.size:
    argument := arguments[index]
    if argument == "--":
      for i := index + 1; i < arguments.size; i++: rest.add arguments[i]
      break  // We're done!

    option := null
    value := null
    if argument.starts_with "--":
      // Get the option name.
      split := argument.index_of "="
      name := (split < 0) ? argument : argument.copy 0 split

      option = grammar.options_.get name --if_absent=: throw "Unknown option $name"
      if split >= 0: value = argument.copy split + 1
    else if argument.starts_with "-":
      // Compute the option and the effective name. We allow short form prefixes to have
      // the value encoded in the same argument like -s"123 + 345", so we have to search
      // for prefixes.
      name := argument
      grammar.options_.get argument
        --if_present=:
          name = argument
          option = it
        --if_absent=:
          grammar.options_.do --keys:
            if argument.starts_with it:
              name = it
              option = grammar.options_[it]
      if not option: throw "Unknown option $argument"

      if name != argument:
        value = argument.copy name.size

    if option:
      if option.is_flag:
        if value: throw "Cannot specify value for boolean flags ($value)"
        value = true
      else if not value:
        if ++index >= arguments.size: throw "No value provided for option $argument"
        value = arguments[index]

      if option.is_multi_option:
        values := option.split_commas ? value.split "," : [value]
        options[option.name].add_all values
      else if seen_options.contains option.name:
        throw "Option was provided multiple times: $argument"
      else:
        options[option.name] = value
        seen_options.add option.name
    else:
      rest.add argument
    index++

  if grammar.rest_minimum and rest.size < grammar.rest_minimum:
    throw "Too few arguments"

  // Construct an [Arguments] object and return it.
  return Arguments command options rest

class Option_:
  name := ?
  is_flag := false
  is_multi_option := false
  split_commas := false  // Only used, if this is a multi-option.
  default := ?

  constructor .name --.is_flag=false --.is_multi_option=false --.split_commas=false --.default=null:
    assert: not split_commas or is_multi_option
