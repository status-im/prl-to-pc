# qt_pkgconfig.nims — prl-to-pc's nimscript consumer interface.
#
# EXECUTE it; never `include` or `import` it:
#
#     nim e --skipParentCfg:on <package root>/qt_pkgconfig.nims <subcommand> [args]
#
# `include`/`import` resolve at PARSE time, while the `--path` switches a
# consumer's `nimble.paths` supplies only take effect at script RUNTIME — and a
# consumer reaches this package through a DYNAMIC store path
# (`<store>/pkgs2/prl_to_pc-<version>-<checksum>`). No consumer `config.nims`
# and no driver script can therefore name this file at parse time. Executing it
# is the only shape that works, and it is why this interface is a script rather
# than an include.
#
# The same knowledge is also published as `qt-pkgconfig.mk` for make consumers.
# The two are one body of knowledge with two front doors: kit derivation, the
# System/Generated probe, tool building and .pc generation. Any change here that
# changes behaviour must change the mk identically, or consumers of the two
# interfaces build against different Qt.
#
# ── Subcommands ──────────────────────────────────────────────────────────────
#
#   env [<buildDir>]
#       Print the pkg-config environment for the active Qt kit to stdout, as
#       `KEY=VAL` lines (one per line, no quoting, no blank lines). Keys:
#
#         QT_PC_MODE                  `system` or `generated` (the probe's answer)
#         QT_PC_REASON                one line saying why that mode was chosen
#         QT_PC_PREFIX                the kit's real Qt install prefix
#         PKG_CONFIG_PATH             directory to PREPEND to the consumer's
#                                     PKG_CONFIG_PATH — the kit's own pkgconfig
#                                     dir (System mode) or this repo's committed
#                                     relocatable tree for the kit (Generated)
#         PKG_CONFIG_PREFIX_OVERRIDE  Generated mode only: resolves the tree's
#                                     `@@QT_PREFIX@@` placeholder to the real kit
#         PKG_CONFIG_ARCH             Generated mode, Android kits only: the ABI
#                                     suffix the wrapper appends to bare module
#                                     names (`Qt6Core` -> `Qt6Core_arm64-v8a`)
#         QT_PC_PATH_PREPEND          Generated mode only: directory to PREPEND
#                                     to PATH so the built wrapper shadows the
#                                     system `pkg-config`
#
#       In System mode the kit's own pkg-config data is authoritative, so no
#       wrapper exists and neither QT_PC_PATH_PREPEND nor the two PKG_CONFIG_*
#       overrides are printed. PKG_CONFIG_PATH still is: without it pkg-config
#       answers from its built-in search path (a brew/distro Qt), not the kit
#       QMAKE selects.
#
#       <buildDir> only names where the wrapper lives (default `<root>/.pcwrap`,
#       the mk's default); consumers of a read-only store copy pass their own.
#       `env` builds nothing and writes nothing.
#
#   tools <buildDir> <consumerPaths>
#       Build the pkg-config wrapper and the prl_to_pc generator into <buildDir>
#       from this package's sources. A no-op in System mode (nothing to build)
#       and on a re-run whose inputs are unchanged (a key file in <buildDir>).
#       <consumerPaths> is the consumer's `nimble.paths`: the generator imports
#       `regex`, and nim disables its default nimblepath whenever the compile's
#       cwd holds a `nimble.lock`, so those paths must be passed explicitly.
#
#   generate [<buildDir> [<consumerPaths>]]
#       Rebuild this kit's committed .pc tree under `<root>/<version>/<kit>`.
#       REFUSES when the package root is a nimble store copy (read-only pinned
#       content, detected by `nimblemeta.json`): new kits are added from a real
#       checkout and committed upstream. A no-op in System mode. Defaults for
#       both arguments match the mk's.
#
# The only inputs are QMAKE (defaults to `qmake` on PATH) and QT_PC_NIM
# (defaults to `nim`) — the same two the mk takes.

import std/[os, strutils, hashes]

# ── plumbing ─────────────────────────────────────────────────────────────────

proc die(msg: string) =
  quit("\nqt_pkgconfig.nims ERROR: " & msg, 1)

proc scriptArgs(): seq[string] =
  ## The parameters after this script's path on the `nim e` command line.
  ## nimscript has no commandLineParams(); paramStr covers the whole nim
  ## command line, flags included.
  var afterFile = false
  for i in 1 .. paramCount():
    let p = paramStr(i)
    if afterFile:
      result.add p
    elif p.endsWith("qt_pkgconfig.nims"):
      afterFile = true

let selfDir = thisDir()        # the package root: committed .pc trees + src/

const
  devNull = if hostOS == "windows": " 2>nul" else: " 2>/dev/null"
  exeExt = if hostOS == "windows": ".exe" else: ""
  pathSep = if hostOS == "windows": ";" else: ":"

proc nimExe(): string =
  result = getEnv("QT_PC_NIM")
  if result.len == 0: result = "nim"

proc qmakeExe(): string =
  result = getEnv("QMAKE")
  if result.len == 0: result = "qmake"

proc qmakeQuery(what: string): string =
  let cmd = quoteShell(qmakeExe()) & " -query " & what
  let (output, rc) = gorgeEx(cmd)
  if rc != 0 or output.strip.len == 0:
    die "'" & cmd & "' produced nothing — is qmake on PATH, or QMAKE set to one?"
  output.strip

proc hasQt6CorePc(dir: string): bool =
  ## Matches the mk's parse-time wildcard: the bare desktop name plus the
  ## Android arch-suffixed one (Qt6Core_arm64-v8a.pc).
  if not dirExists(dir): return false
  if fileExists(dir / "Qt6Core.pc"): return true
  for f in listFiles(dir):
    let n = f.extractFilename
    if n.startsWith("Qt6Core_") and n.endsWith(".pc"): return true

# ── the kit, and the probe that chooses the mode ─────────────────────────────

type Mode = enum mSystem, mGenerated

type Kit = object
  prefix, libs, name, version: string
  pcDir: string        # the kit's OWN pkgconfig dir
  arch: string         # Android ABI suffix ("" elsewhere)
  mode: Mode
  reason: string

proc androidArch(kitName: string): string =
  case kitName
  of "android_arm64_v8a": "arm64-v8a"
  of "android_armv7": "armeabi-v7a"
  of "android_x86_64": "x86_64"
  of "android_x86": "x86"
  else: ""

proc probe(): Kit =
  ## The sole authority for System vs Generated. With the kit's own pkgconfig
  ## dir prepended to PKG_CONFIG_PATH, `pkg-config --variable=libdir Qt6Core`
  ## must string-equal `qmake -query QT_INSTALL_LIBS` exactly. Comparing the
  ## VALUE (not merely `--exists`) is what rejects a wrong kit: a brew or distro
  ## Qt satisfies `--exists` even when QMAKE points somewhere else entirely.
  result.prefix = qmakeQuery("QT_INSTALL_PREFIX")
  result.libs = qmakeQuery("QT_INSTALL_LIBS")
  result.name = result.prefix.lastPathPart
  result.version = result.prefix.parentDir.lastPathPart
  result.pcDir = result.libs / "pkgconfig"
  result.arch = androidArch(result.name)

  let saved = getEnv("PKG_CONFIG_PATH")
  putEnv("PKG_CONFIG_PATH",
    result.pcDir & (if saved.len > 0: pathSep & saved else: ""))
  let (probeLibDir, _) = gorgeEx("pkg-config --variable=libdir Qt6Core" & devNull)
  putEnv("PKG_CONFIG_PATH", saved)

  let kitHasPc = hasQt6CorePc(result.pcDir)
  let libDir = probeLibDir.strip
  if libDir == result.libs:
    result.mode = mSystem
    result.reason = "system mode: Qt6Core.pc libdir matches qmake QT_INSTALL_LIBS"
  else:
    # Either the probe answered nothing (no pkg-config, no Qt6Core anywhere) or
    # it answered with someone else's libdir. The parse-time wildcard separates
    # a kit that ships NO .pc of its own (mobile/embedded shapes — the probe
    # found an ambient Qt6Core) from one that ships a broken-prefix .pc.
    result.mode = mGenerated
    result.reason =
      if not kitHasPc:
        "generated mode: kit ships no Qt6Core.pc in " & result.pcDir
      elif libDir.len == 0:
        "generated mode: kit ships Qt6Core.pc but probe got no answer" &
          " (pkg-config missing or unusable)"
      else:
        "generated mode: Qt6Core.pc libdir mismatch (broken prefix)"

proc committedPcDir(k: Kit): string =
  selfDir / k.version / k.name / "lib" / "pkgconfig"

# ── tool building (never inside the package: <buildDir> is the consumer's) ────

proc isStoreCopy(): bool =
  ## A nimble store copy carries nimblemeta.json at the package root; a git
  ## checkout never does.
  fileExists(selfDir / "nimblemeta.json")

proc genPaths(consumerPaths: string): string =
  ## `--path:` switches that let the generator resolve `regex`/`unicodedb`.
  ## Prefers status-desktop's historical vendored siblings, then the consumer's
  ## nimble-resolved store entries. A standalone clone with neither still
  ## resolves through nim's default nimblepath (`nimble install regex`).
  let sibling = selfDir.parentDir / "nim-regex" / "src"
  if dirExists(sibling):
    return "--path:" & quoteShell(sibling) & " --path:" &
      quoteShell(selfDir.parentDir / "nim-unicodedb" / "src")
  if not fileExists(consumerPaths):
    return ""
  for line in readFile(consumerPaths).splitLines:
    const pre = "--path:\""
    if line.startsWith(pre) and line.endsWith("\""):
      let entry = line[pre.len .. ^2]
      for pkg in ["regex", "unicodedb"]:
        if (DirSep & "pkgs2" & DirSep & pkg & "-") in entry:
          result.add " --path:" & quoteShell(entry)
  result = result.strip

type Tool = object
  name, src, flags: string

proc toolsOf(k: Kit, consumerPaths: string): seq[Tool] =
  @[Tool(name: "pkg-config" & exeExt,
         src: selfDir / "src" / "pkgconfig_wrapper.nim", flags: ""),
    Tool(name: "prl_to_pc" & exeExt,
         src: selfDir / "src" / "prl_to_pc.nim", flags: genPaths(consumerPaths))]

proc toolKey(t: Tool): string =
  ## nimscript has no mtime API, so staleness is keyed on content instead of
  ## timestamps: the source's hash plus everything else that decides the output.
  ## (This is the PRD's key-file gating pattern, not the mtime one.)
  if not fileExists(t.src):
    die "missing tool source " & t.src & " — is this a complete prl-to-pc package root?"
  $hash(readFile(t.src)) & " " & NimVersion & " " & t.flags

proc buildTools(k: Kit, buildDir, consumerPaths: string) =
  if k.mode == mSystem:
    echo "qt-pkgconfig: ", k.reason, " — no tools to build"
    return
  mkDir buildDir
  for t in toolsOf(k, consumerPaths):
    let exe = buildDir / t.name
    let keyFile = buildDir / ("." & t.name & ".key")
    let key = toolKey(t)
    if fileExists(exe) and fileExists(keyFile) and readFile(keyFile) == key:
      continue
    echo "qt-pkgconfig: building ", t.name, " -> ", buildDir
    exec quoteShell(nimExe()) & " c -d:release --hints:off --skipParentCfg:on " &
      t.flags & " -o:" & quoteShell(exe) & " " & quoteShell(t.src)
    writeFile(keyFile, key)

# ── subcommands ──────────────────────────────────────────────────────────────

proc cmdEnv(buildDir: string) =
  let k = probe()
  echo "QT_PC_MODE=", (if k.mode == mSystem: "system" else: "generated")
  echo "QT_PC_REASON=", k.reason
  echo "QT_PC_PREFIX=", k.prefix
  if k.mode == mSystem:
    # The kit's own data is authoritative; nothing is shadowed or overridden.
    echo "PKG_CONFIG_PATH=", k.pcDir
    return
  let pcDir = committedPcDir(k)
  if not hasQt6CorePc(pcDir):
    die "no committed Qt .pc tree for kit '" & k.name & "' of Qt " & k.version &
      " (" & pcDir & ").\n" & k.reason &
      "\nAdd it from a prl-to-pc checkout — `nim e <root>/qt_pkgconfig.nims" &
      " generate` — and commit the tree upstream; store copies are read-only" &
      " pinned content."
  echo "PKG_CONFIG_PATH=", pcDir
  echo "PKG_CONFIG_PREFIX_OVERRIDE=Qt*=", k.prefix
  if k.arch.len > 0:
    echo "PKG_CONFIG_ARCH=", k.arch
  echo "QT_PC_PATH_PREPEND=", buildDir

proc cmdTools(buildDir, consumerPaths: string) =
  buildTools(probe(), buildDir, consumerPaths)

proc cmdGenerate(buildDir, consumerPaths: string) =
  if isStoreCopy():
    die "this prl-to-pc copy is a read-only nimble store copy (" & selfDir &
      ") — refusing to generate a Qt .pc tree into it.\nDevelop prl-to-pc (in" &
      " status-desktop: `nim develop status.nims prl-to-pc`), re-run generate" &
      " against the checkout, and commit the new tree upstream."
  let k = probe()
  if k.mode == mSystem:
    echo "qt-pkgconfig: ", k.reason, " — this kit needs no generated .pc tree"
    return
  buildTools(k, buildDir, consumerPaths)
  echo "qt-pkgconfig: generating Qt .pc for '", k.name, "' from ", k.prefix
  exec quoteShell(buildDir / ("prl_to_pc" & exeExt)) & " generate " &
    quoteShell(k.libs) & " " & quoteShell(selfDir)

# ── dispatch ─────────────────────────────────────────────────────────────────

const usage = """usage: nim e <package root>/qt_pkgconfig.nims <subcommand> [args]

  env [<buildDir>]                      print the kit's pkg-config environment
  tools <buildDir> <consumerPaths>      build the wrapper + generator
  generate [<buildDir> [<consumerPaths>]]  regenerate this kit's committed .pc tree"""

let args = scriptArgs()
if args.len == 0:
  die "no subcommand.\n" & usage

# The mk's defaults, so both interfaces behave identically when a consumer
# passes nothing: tools land beside the sources, and the consumer's nimble.paths
# is assumed two levels up (a `vendor/prl-to-pc` checkout inside a nim project).
let defaultBuildDir = selfDir / ".pcwrap"
let defaultConsumerPaths = selfDir.parentDir.parentDir / "nimble.paths"

proc arg(i: int, fallback: string): string =
  if args.len > i and args[i].len > 0: args[i] else: fallback

case args[0]
of "env":
  if args.len > 2: die "'env' takes at most one argument (<buildDir>).\n" & usage
  cmdEnv(arg(1, defaultBuildDir))
of "tools":
  if args.len != 3:
    die "'tools' takes exactly two arguments (<buildDir> <consumerPaths>).\n" & usage
  cmdTools(args[1], args[2])
of "generate":
  if args.len > 3: die "'generate' takes at most two arguments.\n" & usage
  cmdGenerate(arg(1, defaultBuildDir), arg(2, defaultConsumerPaths))
else:
  die "unknown subcommand '" & args[0] & "'.\n" & usage
