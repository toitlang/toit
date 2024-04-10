// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import ..json-like-encoder_
import .yaml
import io

class YamlEncoder extends EncoderBase_:
  current-line-start-offset_/int := 0
  indent_/int := 0
  enclosed_in_map_ := false
  indent_buffer_/string := "      "  // A buffer of spaces, extends as nescessary.

  /**
  Deprecated.  Use the top level yaml.encode or yaml.stringify functions
    instead.
  Returns an encoder that encodes into an internal buffer.  The
    result can be extracted with $to-string or $to-byte-array.
  */
  constructor:
    super io.Buffer

  /**
  Returns an encoder that encodes onto an $io.Writer.
  */
  constructor.private_ writer/io.Writer:
    super writer

  /** See $EncoderBase_.encode */
  // TODO(florian): Remove when toitdoc compile understands inherited methods
  encode obj/any converter/Lambda:
    return super obj converter

  /** See $EncoderBase_.put-unquoted */
  // TODO(florian): Remove when toitdoc compile understands inherited methods
  put-unquoted data -> none:
    super data

  put-value_ val/string:
    if enclosed_in_map_: writer_.write-byte ' '
    writer_.write val

  encode-string_ str/string:
    // To determine if the str needs to be double quoted, we try to parse it, and if it comes back as a string,
    // then the string can be written in yaml as an unquoted string, i.e "foo" and "bar" does not need to be quoted,
    // but "[a" and "{a" does.
    // Multiline strings will also be quoted even though not strictly necessary in all cases, but will be done
    // for simplicity.
    should_quote := str.contains "\n" or
                    str.contains "\r" or
                    not (parse --on-error=(: null) str) is string

    escaped := escape-string str

    writer := writer_
    if enclosed_in_map_: writer.write-byte ' '

    if should_quote: writer.write-byte '"'
    writer.write escaped
    if should_quote: writer.write-byte '"'

  encode-number_ number:
    // For floating point numbers, the YAML specification has a core tag for float (tag:yaml.org,2002:float)
    // that specifies this regular expression for floats:
    //   [-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?
    // TODO(florian): When the core lib's float can produce that output, then change the following statement.
    str := number is float ? number.stringify 2 : number.stringify
    put-value_ str

  encode-true_:
    put-value_ "true"

  encode-false_:
    put-value_ "false"

  encode-null_:
    // In yaml, a null value is written as an empty string.

  put-new-line:
    writer_.write-byte '\n'
    current-line-start-offset_ = writer_.processed

  close_element_:
    if writer_.processed != current-line-start-offset_:
      put-new-line

  put-indent_:
    if indent_buffer_.size < indent_:
      indent_buffer_ = indent_buffer_ * (indent_ / indent_buffer_.size + 1)
    writer_.write indent_buffer_ 0 indent_

  encode-sub-value_ value --is-map/bool=false new-indent/int [converter]:
    old_indent := indent_
    old_enclosed_in_map := enclosed_in_map_
    indent_ = new-indent
    enclosed_in_map_ = is-map
    encode value converter
    indent_ = old_indent
    enclosed_in_map_ = old_enclosed_in_map

  encode-map_ map/Map [converter]:
    if map.size == 0:
      put-value_ "{}"
      return
    do_indent := false
    if enclosed_in_map_:
      put-new-line
      do_indent = true
    writer := writer_
    map.do: |key value|
      if key is not string:
        throw "INVALID_YAML_OBJECT"
      if do_indent: put-indent_
      do_indent = true
      encode-sub-value_ key indent_ converter
      writer.write-byte ':'
      encode-sub-value_ value --is-map indent_ + 2 converter
      close_element_

  encode-list_ list/List [converter]:
    put-list list.size (: list[it]) converter

  /**
  Outputs a list-like thing to the YAML stream.
  This can be used by converter blocks.
  The generator is called repeatedly with indices from 0 to size - 1.
  */
  put-list size/int [generator] [converter]:
    if size == 0:
      put-value_ "[]"
      return

    if enclosed_in_map_:
      put-new-line
      put-indent_
    writer := writer_
    for i := 0; i < size; i++:
      if i != 0: put-indent_
      writer.write-byte '-'
      writer.write-byte ' '
      encode-sub-value_
          generator.call i
          writer.processed - current-line-start-offset_
          converter
      close_element_
