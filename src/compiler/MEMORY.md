# Compiler allocation ownership

The public `Compiler::compile`, `Compiler::analyze`, and
`Compiler::language_server` entry points establish a `Zone` for each request.
The zone outlives the filesystem, source manager, pipeline, and diagnostics.
Calling the compiler repeatedly releases each request's memory on return.
Existing `exit`/`FATAL` paths still terminate the process; they do not unwind
stack objects. Converting those paths to a reusable error-return API is separate
from allocation ownership.

Compiler helpers used independently (including tests) must establish a zone and
keep it alive while using their results. There is no leaking fallback zone.
Zones nest and the current zone is thread-local. This does not make all other
compiler globals thread-safe.

## Zone allocations

* Every `zone_new<T>` allocation belongs to the current zone. This covers AST,
  IR (including nodes replaced by optimizations), Toitdoc nodes and sources,
  resolver modules and scopes, dispatch selector rows, trie nodes, and source
  manager entries. The zone records the concrete destructor, so STL members are
  destroyed even when a class has no virtual destructor.
* `ListBuilder<T>::allocate`, and consequently every `build` overload, transfers
  backing-array ownership to the current zone. `List` remains a borrowed view;
  copying it or taking a sublist does not transfer ownership. Array elements are
  destroyed with `delete[]`, including nontrivial elements such as `std::string`.
* `Symbol::synthetic` copying overloads and `Symbol::fresh` allocate strings in
  the zone. The `const char*` synthetic overload still borrows its argument;
  string literals need no allocation. Keyword and builtin symbols stay static.
* Other zone strings/buffers: duplicate parameter names (`shape.cc`), converted
  string literals and stripped numeric literals (`resolver_method.cc`), generated
  stub names (`stubs.cc`), setter names (`source_mapper.cc`), source paths
  (`sources.cc`), imported paths and direct-script text (`compiler.cc`), package
  search paths (`lock.cc`), and copied `string_split` input (`util.cc`).
* `LineReader::next` returns zone strings. `LspFsProtocol` adopts SDK and package
  cache response strings into the zone. Localized compilation paths and path
  lists are also adopted using `own_malloc`.

Zone cleanup runs destructors in reverse registration order, then releases arena
chunks. Destructors may release their own buffers and STL storage, but must not
traverse other zone objects. Shared pointers in the compiler graph are borrowed.
Nested zones are suitable only when all values they allocate die together; AST,
IR, symbols, source maps, and type-oracle data currently share the request lifetime
because later passes refer back to earlier ones.

## Individually owned allocations

The following inventory covers the remaining production `new`, `_new`, `malloc`,
`realloc`, `strdup`, and allocating API calls. Multiple sites with the same
contract are grouped. STL allocations are released by their enclosing stack or
zone object's destructor.

| Allocation site | Owner and release |
| --- | --- |
| `zone.h`: arena chunks and cleanup records | `Zone::~Zone`; records live inside chunks. |
| `list.h`: `new T[length]()` | Adopted by `Zone::own_array`; never freed through a `List` view. |
| `compiler.cc`: filesystem, FS connection/protocol, writer, LSP protocol | `language_server`'s `Defer` deletes concrete resources before zone cleanup. |
| `compiler.cc`: `LineReader`'s `getline` buffer | `LineReader::~LineReader`. |
| `compiler.cc`: received snapshot and source-map buffers | `Pipeline::Result::free_all`, after `SnapshotBundle` copies them. |
| `compiler.cc`: `SnapshotGenerator::take_buffer` | Same `Pipeline::Result` ownership. |
| `snapshot_bundle.cc`: SDK version copied while stripping | Local `Defer`; previous value freed if another version entry replaces it. |
| `compiler.cc`: constructed snapshot bundle | Returned to caller; `toitc`, LSP snapshot mode, or embedding caller frees `bundle.buffer()`. |
| `compiler.cc`: copied directory path and case-insensitive match | Local `Defer` and `check_casing` cleanup. |
| `compiler.cc`: normalized completion prefix, import identifier, old-style import segment | Conditional `free` when distinct from borrowed input; longer-lived import identifier adopted into the zone. |
| `compiler.cc`, `lock.cc`: `semver_parse` output | Zero-initialized structs plus `Defer` calling `semver_free`, including parse failure. |
| `backend.cc`: `CompilerProgram` | Zone runs concrete destructor, freeing the separately allocated compiler heap blocks. `Program` members free literal/global tables. |
| `program_builder.cc`: program heap allocation APIs | Heap blocks transfer from `ProgramBuilder` to `CompilerProgram`; builder destructor frees any untransferred blocks. Large external strings/byte arrays borrow zone data. |
| `program_builder.cc`: global/literal table creation | `Program::Table` destructors. Bytecodes and remaining tables use zone lists. |
| `trie.cc`: growing child-pointer array | Old array freed on growth; final array freed by `Trie::~Trie`. Child nodes belong independently to the zone. |
| `scanner.h`: LSP text-with-marker | Stack `LspSource` destructor. |
| `scanner.h`: identifier canonicalization and deprecated underscore spelling | Returns input unchanged or a malloc buffer. Every caller frees only a changed result; the `std::string` overload frees after copying. |
| `parser.h`: scanner-state queue allocation/reallocation | `ScannerStateQueue::~ScannerStateQueue`. |
| `toitdoc_parser.cc`: `memdup` text | `ToitdocSource` destructor, now invoked by the zone. |
| `toitdoc_parser.cc`: escaped-symbol temporary buffer | Freed locally after copying into `std::string`. |
| `source_mapper.cc`: cooked source map | Returned to `Pipeline::Result`; freed after bundle construction. |
| `label.h`: `AbsoluteUse` | `ByteGen::update_absolute_positions` calls `AbsoluteReference::free_absolute_uses`. Label/reference lists only borrow these pointers. |
| `filesystem.cc`: current directory, library root, vessel root | `Filesystem::~Filesystem`. |
| `filesystem.cc`: extension-stripped/normalized filenames | Freed in the directory callback, accounting for the unchanged-input case. |
| `filesystem_local.cc`: executable path | Cached as `sdk_path_`; filesystem destructor uses platform-specific allocator pairing. |
| `filesystem_local.cc`: package cache string/default path | `FilesystemLocal::~FilesystemLocal`; the list of slices is zone-owned. |
| `filesystem_local.cc`: file contents | Freed on read failure; successful buffers retained by the filesystem and freed in its destructor. Intercepted input remains borrowed. |
| `filesystem_local_win.cc`: relative drive anchor | Retained with filesystem-owned buffers and freed in its destructor; freed immediately on API failure. |
| `filesystem_local_{posix,win}.cc`: single `to_local_path` result | Caller owns malloc buffer: adopted for compilation, freed by `Filesystem` for library root, or freed locally in package-lock handling. |
| `filesystem_local_{posix,win}.cc`, `filesystem_{lsp,archive}.h`: root string | `PackageLock` root search copies it, then calls `delete[]`. |
| `util.h`: `PathBuilder::strdup` | Caller-owned malloc buffer: filesystem roots/cache path or local directory-path cleanup. Retained compiler paths use `Zone::strdup` instead. |
| `util.cc`: canonicalization temporary | Freed after copying back into `std::string`. |
| `lock.cc`: `compute_package_cache_path_from_home` | Returned malloc string owned by `FilesystemLocal`. |
| `lock.cc`: libyaml parser/events | `YamlParser` deletes each consumed event and deletes the last event/parser at destruction. |
| `tar.cc`: combined/copied names and file contents | Transferred to callback on success; freed on short read, allocation failure, skipped entries, and pending long-name cleanup. |
| `filesystem_archive.cc`: tar callback data | Name freed immediately; content owned by archive map, including replacement of duplicate entries and filesystem destruction. Metadata and directory views borrow the content. |
| `executable.cc`: mutable signing path and vessel contents | Local `free` / `Defer` on success and error returns. |
| `dep_writer.cc`: previous dependency-file contents | Freed on failed read, or after comparing/writing dependencies. |
| `windows.cc`: `getline` allocation/reallocation | Caller owns returned buffer; `LineReader` frees it. Failed realloc preserves the caller's pointer. |
| `lsp/lsp.h`: selection handlers | `Lsp::~Lsp`; handler base destructor is virtual. |
| `lsp/fs_connection_socket.cc`, `lsp/multiplex_stdout.cc`: response lines | Transferred to `LspFsProtocol`; transient responses freed locally, retained path responses adopted into the zone. |
| `lsp/fs_protocol.cc`: fetched content | `FilesystemLsp` cache owns and frees content in its destructor. Content-size response freed immediately. |
| `lsp/protocol_summary.cc`: writer buffer/growth and name temporary | Writer destructor and local `free`; replaced buffers freed on growth. |
| `propagation/type_database.cc`: database | Compiler deletes after use; destructor removes its cache entry. The optional type-checking interpreter retains databases in a process-lifetime owning cache, whose destructor deletes remaining entries. |
| `propagation/type_database.cc`: method/input/type-block stacks | `TypeDatabase::~TypeDatabase`. |
| `propagation/type_propagator.cc`: field/global/output/input variables | Owning maps/vectors released by `TypePropagator::~TypePropagator`; output sets borrow variables. |
| `propagation/type_propagator.cc`: method/block templates | Propagator owns chain heads; template destructors release successor chains. |
| `propagation/type_propagator.h`: block argument array/variables | `BlockTemplate::~BlockTemplate`. |
| `propagation/type_scope.cc`: stack objects/copies and wrapped-pointer arrays | Scope owns stacks marked copied and releases them and its pointer array in its destructor. Borrowed stacks stay with the original scope. |
| `propagation/type_scope.cc`, `type_propagator.cc`: scopes and lazy copies | Transferred to worklists or deleted locally after merging/processing. `Worklist::~Worklist` frees retained scopes. |
| `propagation/type_stack.h`, `type_variable.h`: bit arrays | Corresponding destructors; copied stacks follow the same scope/database ownership. |

## Vendored code and accepted leaks

No compiler allocation in this inventory is classified as a **minor leak that is
accepted**. Constant strings use static storage or a zone.

Vendored libraries keep their native allocators: semver's temporary buffer is
freed inside `semver_parse`, and metadata/prerelease allocations are released by
our `semver_free` calls. Libyaml's allocation/reallocation/string duplication
helpers are paired with its parser/event deletion APIs. Nlohmann JSON owns its
storage through C++ destructors. Their unused emitter/document APIs and upstream
test programs are not part of the compiler's allocation graph and were not
converted to zones.

## Validation

`compiler-zone-test.cc` checks nested lifetime restoration, concrete destructors,
nontrivial list elements, chunk growth/alignment, adopted buffers, and thread-local
zones. `compiler-memory-test.cc` compiles repeatedly without forking at levels
0–2, uses returned bundles after zone destruction, and checks LSP filesystem cache and borrowed-input ownership. Run both under a leak
checker to catch retained allocations as well as invalid accesses.

For AddressSanitizer builds, use `alloc_dealloc_mismatch=0`: `src/top.cc` overrides
C++ allocation operators with `malloc`, so ASan's default allocator-family check
reports those existing overrides. Leak and invalid-access checks remain enabled.

Validation for this change on Linux: 634 CTest checks passed across compiler,
negative, optimization, type-propagation, package-lock, Toitdoc, LSP, stripping,
and focused runtime/native tests. The three native ownership tests, optimized
compilation/stripping, and LSP analysis also passed AddressSanitizer and
LeakSanitizer with no reported leaks or invalid accesses. Windows allocation
paths were reviewed but not executed on this host.

The sanitizer native tests were linked against `toit_compiler`/`toit_core`; the
usual test link against `toit_vm` encountered unresolved
`SweepingVisitor::add_free_list_region` symbols in the sanitizer configuration.
Valgrind could not start with the host's stripped libc loader. LeakSanitizer
checks ran outside the sandbox because its thread scan is restricted there.
