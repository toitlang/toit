---
name: toit-toitdoc
description: Guidelines and conventions for writing Toitdoc comments when documenting Toit code.
---

# Toitdoc Skill
This skill provides instructions on how to write concise and properly formatted Toitdoc documentation for Toit code. Keep it helpful for both API callers and subclass developers.

Put library comments after the import lines.

Prefer slightly to put general documentation into library comments over class comments.

## Syntax and Basics
- Use `/** ... */` comments, even for single lines. They are preferred over `///`.
- Start every documentation block with a short descriptive sentence. It's okay to duplicate the element name.
- For multi-line comments, DO NOT use a leading `*` on each line. Align the text with the first `/`:
  ```toit
  /**
  This is a short summary.
  It spans multiple lines without leading asterisks.
  */
  ```

## Formatting
- **Paragraphs**: New lines create new paragraphs automatically, unless the new line is indented further than the previous line.
- **Emphasis**: Use `*important*` to emphasize text.
- **Code spans**: Enclose code in backticks (`code`). Whitespace inside spans is reduced to a single space.
- **Code blocks**: Use triple backticks (```) for fenced code blocks. Separate multiple code blocks (e.g., different examples) with their own fenced blocks.
- **Do not code-format** `true`, `false`, or `null`. Write them as normal text.

## Links and References
- Prefix names with `$` to natively link to elements (e.g., `Returns $element-name`). This is fine to refer to any of the methods if there is overloading.
- Link elements taking arguments explicitly: `$(method arg1 arg2)`. Use this if you want to link to *that* specific method.
- URLs (`http://...`) and file paths (`file://...`) are automatically linked.

## Sections
Use markdown headings (e.g. `# Advanced`) for specific sections. Follow these conventions:
- **Advanced**: Explanations (like algorithms) non-essential for general use. These are collapsed by default.
- **Inheritance**: Information only relevant for developers subclassing or extending the element.
- **Errors**: Used to document exceptions and how to deal with common problems or mistakes. We tend to use "It is an error" when the API is used the wrong way. If it is an exception (correct use of API, but unexpected things), specify what is thrown.
- **Aliases**: A markdown list of alternative names (e.g. `- push` for `List.add`) to help users search for methods from other languages.
- **Examples**: Used to demonstrate usage with code blocks. Place this as the last section (save for Categories).

## Vocabulary
Always use standard terminology for consistency:
- "Class"
- "Global" (for global variables)
- "Function" (for global functions)
- "Constructor"
- "Factory"
- "Field"
- "Method" (or "getter"/"setter")
- "Block"
- "Lambda" (preferred over "closure")

## Receivers
Toitdocs can be for libraries (Toit files), globals (including classes), and any member.

Library toitdocs typically follow the imports.
They must not be attached to any global (or class), as that would attach it to them.

Example:
```
import io

/**
A zlib parser.
*/

/**
Decoder for Zlib streams.
*/
class Decoder:
...
```

## Length
All examples in this document are short, but it is not uncommon to have multiple
paragraphs.

```
/**
Some short description.

Returns xyz.

More information.
Paragraphs can be attached, if they are related.

# Some section
More information
*/
```
Don't force yourself to write long toitdocs, but if there is interesting
information don't limit yourself either.


## Verification
Use 'toit analyze' to see whether references are correct (or at least not bad).
