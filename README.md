# prl-to-pc — relocatable pkg-config for Qt kits

Qt ships `.prl` (qmake link metadata) files instead of pkg-config `.pc`
files. This repo makes any Qt kit consumable through the standard
`pkg-config` interface, on every platform, without a per-machine setup step.

It is three layers plus a make include that glues them together:

1. **Committed, relocatable `.pc` trees** — one per Qt version/kit, mirroring
   Qt's own layout:

   ```
   <version>/<kit>/lib/pkgconfig/*.pc      # e.g. 6.11.0/macos/lib/pkgconfig
   ```

   Currently committed for Qt 6.11.0: `macos`, `ios`, `android_arm64_v8a`,
   `msvc2022_64`. Each `.pc` bakes the placeholder prefix `@@QT_PREFIX@@`
   instead of a real path — the tree is machine-independent and the real
   prefix is supplied at query time (layer 3).

2. **The generator** (`src/prl_to_pc.nim`) — converts a kit's `.prl` files
   (and iOS `.framework`s) into those `.pc` files. It reconstructs what
   `.prl` files don't carry: `Requires:` edges come from the .prl's
   CMake-libs line, or from Qt's `<Module>Dependencies.cmake` on platforms
   whose `.prl`s have no dependency info (Windows); static/framework/ABI
   variants get correct `Libs:`/`Cflags:`; everything is emitted
   `${prefix}`-relative so the tree stays relocatable.

3. **A unified `pkg-config` wrapper** (`src/pkgconfig_wrapper.nim`) — built
   as `pkg-config` (`.exe` on Windows) and placed first on `PATH`, shadowing
   the real tool. For package names matching `PKG_CONFIG_PREFIX_OVERRIDE` it
   prepends `--define-variable=prefix=<real prefix>` and delegates to the
   first real `pkgconf`/`pkg-config` found on `PATH` (recursion-guarded
   three ways). This is what resolves `@@QT_PREFIX@@` to the actual kit:

   ```
   PKG_CONFIG_PREFIX_OVERRIDE='Qt*=/Users/you/Qt/6.11.0/macos'   # pattern=prefix, comma-separated
   PKG_CONFIG_ARCH='arm64-v8a'   # android single-arch kits only: Qt6Core -> Qt6Core_arm64-v8a
   PKG_CONFIG_PATH=<this repo>/6.11.0/macos/lib/pkgconfig
   ```

   The wrapper also strips trailing whitespace from output (Nim's `gorge`
   keeps the LF of a CRLF, which breaks numeric parsing in consumers like
   seaqt). For non-matching packages it is a transparent pass-through.

4. **`qt-pkgconfig.mk`** — a zero-config include for GNU-make consumers that
   wires the above together (see below).

A real `pkg-config` or `pkgconf` must exist somewhere on `PATH`; the wrapper
delegates to it and refuses to run if it can only find itself.

## Consuming from a Makefile (`qt-pkgconfig.mk`)

```make
include path/to/prl-to-pc/qt-pkgconfig.mk
```

The **only input is `QMAKE`** (defaults to `qmake` on `PATH`) — the kit,
version, platform and android ABI are all derived from
`qmake -query QT_INSTALL_PREFIX`. The include:

- builds the wrapper (and, only when needed, the generator) into
  `QT_PC_BUILD_DIR`;
- selects this kit's committed `.pc` tree, or schedules generation when the
  kit has none;
- exports the wrapper env (`PKG_CONFIG_PATH`, `PKG_CONFIG_PREFIX_OVERRIDE`,
  `PKG_CONFIG_ARCH` on android, wrapper dir prepended to `PATH`) so recipes
  and Nim-compile-time `gorge("pkg-config …")` calls just work.

Targets:

| target | purpose |
|---|---|
| `qt-pkgconfig` | aggregate: wrapper built + this kit's `.pc` tree present. Add as an order-only prerequisite of your build. |
| `qt-pkgconfig-tools` | build wrapper + generator executables. |
| `qt-pkgconfig-generate` | (re)generate this kit's `.pc` tree from the `QMAKE` kit — run on a Qt version bump and **commit the result**. |

Variables the includer may read: `QT_PCFILEDIR` (committed `.pc` dir for the
active kit), `QT_PC_PKGCONFIG` (wrapper path), `QT_PC_GENERATOR`,
`QT_PC_PREFIX` (real kit prefix).

Consumer-overridable knobs (set **before** the `include`):

- `QT_PC_BUILD_DIR` (default `<this repo>/.pcwrap`) — where the wrapper and
  generator binaries are built. **Must be overridden to a consumer-local dir
  when this repo is consumed as a read-only copy** (e.g. a nimble store
  entry); nothing may write into such a copy.
- `QT_PC_CONSUMER_PATHS` (default `<this repo>/../../nimble.paths`) — a
  nimble `nimble.paths` file used to resolve the generator's `regex`/
  `unicodedb` dependencies when the sibling-checkout layout (below) is
  absent.
- `QT_PC_NIM` (default `nim`) — the Nim compiler used to build the tools.

### How the generator's own deps resolve

The wrapper is dependency-free; only the generator imports `regex`. Its
build resolves paths in this order:

1. sibling checkouts `../nim-regex/src` + `../nim-unicodedb/src` (the
   vendored-submodule layout — offline);
2. explicit `--path` flags parsed from `QT_PC_CONSUMER_PATHS`;
3. nothing — a standalone clone falls back to Nim's default nimblepath
   (`nimble install regex`). Caveat: Nim **disables** its default
   `~/.nimble/pkgs2` search when the compile's working directory contains a
   `nimble.lock`, so consumers with a lock file must provide 1 or 2.

## Consuming as a nimble dependency

```nim
requires "https://github.com/status-im/prl-to-pc.git#v0.2.0"
```

The package is consumed as **package-root files** (the mk include and the
`.pc` trees), not as Nim modules. Its manifest deliberately declares
**neither `bin` nor `srcDir`** — both are load-bearing for store copies on
nimble 0.22.x:

- a dependency with `bin` is **built unconditionally during every consumer's
  `nimble setup`** (there is no skip mechanism); the tools are built on
  demand by `qt-pkgconfig.mk` instead;
- a dependency with `srcDir` gets its store copy **hoisted and stripped to
  the srcDir contents** — `qt-pkgconfig.mk` and the `.pc` trees would simply
  not exist in the store. Without it, the full repo tree is materialized.

`regex`/`unicodedb` are pinned by revision (name-form requires in dependency
manifests make consumer solves nondeterministic).

The consumer resolves the package root from its generated `nimble.paths`
(the `pkgs2/prl_to_pc-…` entry), includes `<root>/qt-pkgconfig.mk`, and sets
`QT_PC_BUILD_DIR` (+ `QT_PC_CONSUMER_PATHS`) as described above. Store
copies are read-only pinned content: `qt-pkgconfig-generate` detects them
(`nimblemeta.json` at the package root) and **refuses to write** — new kits
are generated from a real checkout and committed upstream. Reference
consumer: status-desktop (`Makefile` + `config.nims` + the
`nim develop status.nims prl-to-pc` flow).

## Adding a kit / bumping Qt

From a real checkout (not a store copy), with the target kit's qmake:

```bash
QMAKE=~/Qt/6.12.0/macos/bin/qmake make -f qt-pkgconfig.mk qt-pkgconfig-generate
git add 6.12.0/macos/lib/pkgconfig && git commit
```

(In status-desktop: `nim develop status.nims prl-to-pc`, then
`make qt-pkgconfig-generate`.) Generation is idempotent — the kit's output
dir is wiped and rewritten.

## Command-line usage

```bash
# Relocatable committed-tree mode (what qt-pkgconfig-generate runs):
# derives <version>/<kit> from the path, writes
# <out_root>/<version>/<kit>/lib/pkgconfig with the @@QT_PREFIX@@ placeholder.
prl_to_pc generate <qt_lib_dir> [out_root]

# Raw conversion with a literal prefix (host_bins defaults to ${prefix}/bin):
prl_to_pc [convert] <input_dir> <output_dir> <prefix> [host_bins]
```

Build the tools with `make -f qt-pkgconfig.mk qt-pkgconfig-tools`, or
directly: `nim c -d:release src/prl_to_pc.nim` (needs `regex` resolvable —
see above; the wrapper `src/pkgconfig_wrapper.nim` is dependency-free).

## Library usage

```nim
import prl_to_pc  # compile with --path:<repo>/src

# One .prl file / one iOS framework:
let module = parsePrlFile("path/to/Qt6Core.prl")
let fw     = parseFramework("path/to/QtCore.framework")

# Whole kit, literal prefix:
convertPrlToPc("qt/lib", "out/pkgconfig", "/path/to/qt/kit", "")

# Whole kit, relocatable committed-tree layout:
generateBundled("~/Qt/6.11.0/macos/lib", "out/root")
```

## Tests

```bash
nimble test
```

Runs the wrapper's unit tests (glob/override/arch-suffix logic) plus a
minimal-project compile check that each committed `.pc` tree resolves
correct include paths: it queries cflags through the wrapper and compiles a
tiny Qt translation unit per kit. Kits whose real Qt install or platform
compiler is absent are **skipped**, so the suite runs on any one machine
(real kits are looked up under `$QT_KITS_DIR/<kit>`, default
`$HOME/Qt/<version>/<kit>`).

## License

MIT — see [LICENSE](LICENSE).
