## tests/test_qt_pkgconfig_nims.nim
##
## Hermetic fixture-Kit harness for qt_pkgconfig.nims — the EXECUTED consumer
## interface (`nim e <package root>/qt_pkgconfig.nims <subcommand>`).
##
## Sibling of test_qt_pkgconfig_mk.nim, which pins the same contract for the
## make interface. The two interfaces publish one body of knowledge (kit
## derivation, the Probe, tool building, .pc generation), so both suites drive
## the same three fixture Kit variants and assert the same choices:
##
##   correct       Kit ships a pkgconfig/ dir whose Qt6Core.pc libdir matches
##                 qmake's QT_INSTALL_LIBS.  Probe passes -> System mode.
##   broken-prefix Kit ships a Qt6Core.pc pointing at a build-farm libdir.
##                 Probe sees a mismatch -> Generated mode.
##   no-pc         Kit ships no pkgconfig/ dir (mobile-Kit shape).
##                 Probe finds no usable Qt6Core.pc -> Generated mode.
##
## In System mode `env` names the Kit's own pkgconfig dir and nothing else: no
## wrapper exists, so no PATH prepend and no prefix override are printed, and
## `tools` builds nothing.  In Generated mode `env` names this repo's committed
## relocatable tree, the prefix override and the wrapper dir.
##
## Requirements: nim on PATH plus a real system pkg-config (the repo's dev
## baseline) — the correct/System fixture needs pkg-config to answer the Probe.
## No real Qt install required.  Each test run creates a fresh temp sandbox.
##
## The `tools` build of the generator needs `regex`; the tests that exercise it
## are skipped when no nimble.paths can supply it (see consumerPaths()).

import std/[unittest, os, osproc, strutils]

const
  FakeVersion = "6.9.0"
  FakeKit     = "macos"

let here = currentSourcePath().parentDir()
let repo = here.parentDir()   # prl-to-pc root

# ─── sandbox helpers ─────────────────────────────────────────────────────────

proc freshSandbox(variant: string): string =
  let d = getTempDir() / "prl_to_pc_nims_" & variant
  removeDir(d)
  createDir(d)
  d

proc stageModule(sandboxDir: string): string =
  ## Stage qt_pkgconfig.nims + src/ into <sandbox>/module/ so `nim e` runs
  ## against the sandbox, never the live checkout.  Returns the module dir —
  ## which plays the part of the package root.
  let modDir = sandboxDir / "module"
  createDir(modDir)
  copyFile(repo / "qt_pkgconfig.nims", modDir / "qt_pkgconfig.nims")
  let srcDst = modDir / "src"
  createDir(srcDst)
  for kind, path in walkDir(repo / "src"):
    if kind == pcFile:
      copyFile(path, srcDst / path.extractFilename)
  modDir

proc seedCommittedTree(modDir: string) =
  ## A minimal committed .pc tree for the fixture Kit, so Generated-mode `env`
  ## finds one and does not fail.
  let pcDir = modDir / FakeVersion / FakeKit / "lib" / "pkgconfig"
  createDir(pcDir)
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=@@QT_PREFIX@@\n" &
    "libdir=${prefix}/lib\n" &
    "Name: Qt6Core\nDescription: Qt6Core\nVersion: " & FakeVersion & "\n")

proc createFakeQmake(sandboxDir, kitPrefix, kitLibs: string): string =
  let binDir = sandboxDir / "bin"
  createDir(binDir)
  let qmakePath = binDir / "qmake"
  writeFile(qmakePath,
    "#!/bin/sh\n" &
    "case \"$2\" in\n" &
    "  QT_INSTALL_PREFIX) echo " & quoteShell(kitPrefix) & " ;;\n" &
    "  QT_INSTALL_LIBS)   echo " & quoteShell(kitLibs)   & " ;;\n" &
    "  *) exit 1 ;;\n" &
    "esac\n")
  setFilePermissions(qmakePath,
    {fpUserExec, fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
  qmakePath

proc runNims(modDir, qmakePath: string,
             args: openArray[string]): tuple[output: string, code: int] =
  ## `nim e` the staged interface.  --skipParentCfg keeps a temp dir's (or a
  ## consumer's) enclosing configs out of the evaluation, exactly as consumers
  ## are documented to invoke it.
  var cmd = quoteShell(findExe("nim")) & " e --skipParentCfg:on --hints:off " &
    quoteShell(modDir / "qt_pkgconfig.nims")
  for a in args:
    cmd.add " " & quoteShell(a)
  let (output, exitCode) = execCmdEx("QMAKE=" & quoteShell(qmakePath) & " " & cmd)
  (output, exitCode)

proc parseKV(output: string): seq[tuple[k, v: string]] =
  for line in output.splitLines:
    let trimmed = line.strip()
    if trimmed.len == 0: continue
    let sep = trimmed.find('=')
    if sep < 0: continue
    result.add (trimmed[0 ..< sep], trimmed[sep + 1 .. ^1])

proc valueOf(pairs: seq[tuple[k, v: string]], key: string): string =
  for p in pairs:
    if p.k == key: return p.v
  ""

proc hasKey(pairs: seq[tuple[k, v: string]], key: string): bool =
  for p in pairs:
    if p.k == key: return true

proc consumerPaths(): string =
  ## A nimble.paths that can resolve `regex`/`unicodedb` for the generator
  ## build: this package's own (a standalone clone that ran `nimble setup`), or
  ## the consumer's two levels up (a `vendor/prl-to-pc` checkout — the mk's
  ## default).  "" when neither exists: the tools tests then skip.
  for candidate in [repo / "nimble.paths",
                    repo.parentDir.parentDir / "nimble.paths"]:
    if fileExists(candidate) and "regex-" in readFile(candidate):
      return candidate
  ""

# ─── fixture Kit constructors (identical to the mk suite's) ──────────────────

proc makeCorrectKit(sandboxDir, kitLibDir: string) =
  let pcDir = kitLibDir / "pkgconfig"
  createDir(pcDir)
  let kitRoot = sandboxDir / "fakekit" / FakeVersion / FakeKit
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=" & kitRoot & "\n" &
    "libdir=" & kitLibDir & "\n" &
    "Name: Qt6Core\nDescription: Qt6Core\nVersion: " & FakeVersion & "\n")

proc makeBrokenPrefixKit(kitLibDir: string) =
  let pcDir = kitLibDir / "pkgconfig"
  createDir(pcDir)
  writeFile(pcDir / "Qt6Core.pc",
    "prefix=/Users/qt/work/install\n" &
    "libdir=/Users/qt/work/install/lib\n" &
    "Name: Qt6Core\nDescription: Qt6Core\nVersion: " & FakeVersion & "\n")

proc makeNoPcKit(kitLibDir: string) =
  createDir(kitLibDir)

type Fixture = object
  sandbox, modDir, qmake, kitPrefix, kitLibs, buildDir: string

proc fixture(variant: string, seed = true): Fixture =
  result.sandbox = freshSandbox(variant)
  # Canonicalized: nim resolves the script's path before handing it to
  # thisDir(), so a sandbox reached through a symlink (macOS /var ->
  # /private/var) would otherwise never match the paths the script prints.
  result.modDir = expandFilename(stageModule(result.sandbox))
  if seed: seedCommittedTree(result.modDir)
  result.kitPrefix = result.sandbox / "fakekit" / FakeVersion / FakeKit
  result.kitLibs = result.kitPrefix / "lib"
  result.qmake = createFakeQmake(result.sandbox, result.kitPrefix, result.kitLibs)
  result.buildDir = result.sandbox / "consumer-build"

# ─── test cases ──────────────────────────────────────────────────────────────

suite "qt_pkgconfig.nims: env — the probe-selected environment":

  test "correct Kit — System mode: the Kit's own pkgconfig dir, nothing else":
    let f = fixture("correct")
    makeCorrectKit(f.sandbox, f.kitLibs)
    let (output, code) = runNims(f.modDir, f.qmake, ["env", f.buildDir])
    check code == 0
    let kv = parseKV(output)
    check valueOf(kv, "QT_PC_MODE") == "system"
    check valueOf(kv, "QT_PC_REASON").contains("system mode")
    check valueOf(kv, "QT_PC_PREFIX") == f.kitPrefix
    # PKG_CONFIG_PATH is still printed: without it pkg-config answers from its
    # built-in search path (a brew/distro Qt), not the Kit QMAKE selects.
    check valueOf(kv, "PKG_CONFIG_PATH") == f.kitLibs / "pkgconfig"
    # No wrapper exists in System mode, so nothing shadows PATH and no
    # relocatable-prefix placeholder needs resolving.
    check not hasKey(kv, "QT_PC_PATH_PREPEND")
    check not hasKey(kv, "PKG_CONFIG_PREFIX_OVERRIDE")
    check not hasKey(kv, "PKG_CONFIG_ARCH")

  test "broken-prefix Kit — Generated mode: committed tree, override, wrapper dir":
    let f = fixture("broken")
    makeBrokenPrefixKit(f.kitLibs)
    let (output, code) = runNims(f.modDir, f.qmake, ["env", f.buildDir])
    check code == 0
    let kv = parseKV(output)
    check valueOf(kv, "QT_PC_MODE") == "generated"
    check valueOf(kv, "QT_PC_REASON").contains("libdir mismatch (broken prefix)")
    check valueOf(kv, "PKG_CONFIG_PATH") ==
      f.modDir / FakeVersion / FakeKit / "lib" / "pkgconfig"
    check valueOf(kv, "PKG_CONFIG_PREFIX_OVERRIDE") == "Qt*=" & f.kitPrefix
    check valueOf(kv, "QT_PC_PATH_PREPEND") == f.buildDir

  test "no-pc Kit — Generated mode, and the reason names the missing .pc":
    ## Deterministic even on machines whose pkg-config resolves an ambient
    ## Qt6Core (brew): the reason comes from a wildcard over the Kit's own dir,
    ## not from the probe's answer.
    let f = fixture("nopc")
    makeNoPcKit(f.kitLibs)
    let (output, code) = runNims(f.modDir, f.qmake, ["env", f.buildDir])
    check code == 0
    let kv = parseKV(output)
    check valueOf(kv, "QT_PC_MODE") == "generated"
    check valueOf(kv, "QT_PC_REASON").contains("kit ships no Qt6Core.pc")

  test "Generated mode without a committed tree — env fails, actionably":
    let f = fixture("notree", seed = false)
    makeBrokenPrefixKit(f.kitLibs)
    let (output, code) = runNims(f.modDir, f.qmake, ["env", f.buildDir])
    check code != 0
    check output.contains("no committed Qt .pc tree for kit '" & FakeKit & "'")
    check output.contains("generate")

suite "qt_pkgconfig.nims: tools — built for the consumer, never into the package":

  test "System mode builds nothing at all":
    let f = fixture("tools-system")
    makeCorrectKit(f.sandbox, f.kitLibs)
    let (output, code) = runNims(f.modDir, f.qmake,
      ["tools", f.buildDir, consumerPaths()])
    check code == 0
    check output.contains("no tools to build")
    check not dirExists(f.buildDir)

  test "Generated mode builds both tools into <buildDir>, and re-runs are no-ops":
    let cp = consumerPaths()
    if cp.len == 0:
      skip()  # no nimble.paths can resolve `regex` for the generator build
    else:
      let f = fixture("tools-generated")
      makeBrokenPrefixKit(f.kitLibs)
      let (_, code) = runNims(f.modDir, f.qmake, ["tools", f.buildDir, cp])
      check code == 0
      check fileExists(f.buildDir / "pkg-config".addFileExt(ExeExt))
      check fileExists(f.buildDir / "prl_to_pc".addFileExt(ExeExt))
      # The package root is pinned content for a store consumer: nothing may be
      # written beside the sources.
      check not dirExists(f.modDir / ".pcwrap")
      # A second run must not recompile: the key file records the sources.
      let (again, code2) = runNims(f.modDir, f.qmake, ["tools", f.buildDir, cp])
      check code2 == 0
      check not again.contains("building")

suite "qt_pkgconfig.nims: generate — refuses to write into a store copy":

  test "a store copy (nimblemeta.json at the root) is refused, with the remedy":
    let f = fixture("generate-store")
    makeBrokenPrefixKit(f.kitLibs)
    writeFile(f.modDir / "nimblemeta.json", "{\"version\": 1}")
    let (output, code) = runNims(f.modDir, f.qmake,
      ["generate", f.buildDir, consumerPaths()])
    check code != 0
    check output.contains("read-only nimble store copy")
    check output.contains("nim develop status.nims prl-to-pc")
    # Refused before anything was built or written.
    check not dirExists(f.buildDir)

  test "the refusal precedes the probe: a System-mode store copy is refused too":
    let f = fixture("generate-store-system")
    makeCorrectKit(f.sandbox, f.kitLibs)
    writeFile(f.modDir / "nimblemeta.json", "{\"version\": 1}")
    let (output, code) = runNims(f.modDir, f.qmake,
      ["generate", f.buildDir, consumerPaths()])
    check code != 0
    check output.contains("read-only nimble store copy")

  test "a System-mode checkout needs no tree, and says so":
    let f = fixture("generate-system")
    makeCorrectKit(f.sandbox, f.kitLibs)
    let (output, code) = runNims(f.modDir, f.qmake,
      ["generate", f.buildDir, consumerPaths()])
    check code == 0
    check output.contains("needs no generated .pc tree")

suite "qt_pkgconfig.nims: dispatch":

  test "no subcommand, and unknown subcommands, fail with the usage":
    let f = fixture("usage")
    makeCorrectKit(f.sandbox, f.kitLibs)
    for args in [@[], @["nonsense"]]:
      let (output, code) = runNims(f.modDir, f.qmake, args)
      check code != 0
      check output.contains("usage: nim e")
