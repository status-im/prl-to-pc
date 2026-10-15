## Minimal-project compile test for the committed Qt .pc trees.
##
## For each committed kit under <repo>/<version>/<kit>/lib/pkgconfig, this:
##   1. builds the pkg-config wrapper from src,
##   2. asks it (with PKG_CONFIG_PREFIX_OVERRIDE -> the real Qt kit, and
##      PKG_CONFIG_ARCH for android) for the cflags of the core Qt modules,
##   3. compiles a tiny Qt translation unit (-c, no link) with the platform
##      compiler, proving the committed .pc resolve correct -I/-F include paths.
##
## This is exactly the surface seaqt hits via gorge("pkg-config ...") at
## nim-compile time. It is compile-only, so it does not depend on Qt link slices
## (e.g. iOS device-vs-simulator) — only header resolution.
##
## A kit's sub-test is SKIPPED (not failed) when its real Qt kit or its platform
## compiler/NDK is unavailable, so the suite is runnable on any single machine
## and per-platform in CI. The real kits are looked up under
## $QT_KITS_DIR/<kit> (default: $HOME/Qt/<version>/<kit>).

import std/[unittest, os, osproc, strutils]

let here = currentSourcePath().parentDir()
let repo = here.parentDir()                       # vendor/prl-to-pc

# --- build the wrapper once -------------------------------------------------
let tmp = getTempDir() / "prl_pc_compile_test"
removeDir(tmp)
createDir(tmp)
let exeExt = when defined(windows): ".exe" else: ""
let wrapExe = tmp / "pkg-config" & exeExt
block:
  let wrapSrc = repo / "src" / "pkgconfig_wrapper.nim"
  let (outp, code) = execCmdEx("nim c --hints:off --skipParentCfg:on -o:" &
    quoteShell(wrapExe) & " " & quoteShell(wrapSrc))
  doAssert code == 0, "failed to build pkg-config wrapper:\n" & outp

# Modules a typical seaqt build resolves, with one header each to #include.
const QtModules = ["Qt6Core", "Qt6Gui", "Qt6Qml", "Qt6Quick"]
const TU = """
#include <QObject>
#include <QGuiApplication>
#include <QQmlEngine>
#include <QQuickItem>
int main() { return 0; }
"""

proc wrapperCflags(pcDir, realPrefix, arch: string): tuple[ok: bool, flags: string] =
  ## Drive the wrapper exactly as the build does and capture --cflags.
  putEnv("PKG_CONFIG_PATH", pcDir)
  putEnv("PKG_CONFIG_PREFIX_OVERRIDE", "Qt*=" & realPrefix)
  if arch.len > 0: putEnv("PKG_CONFIG_ARCH", arch) else: delEnv("PKG_CONFIG_ARCH")
  delEnv("STATUS_PKGCONFIG_WRAP_ACTIVE")
  let (outp, code) = execCmdEx(quoteShell(wrapExe) & " --cflags " & QtModules.join(" "))
  result = (code == 0, outp.strip())

proc compileTU(compiler, extraArgs, cflags: string): tuple[ok: bool, output: string] =
  let tu = tmp / "tu.cpp"
  writeFile(tu, TU)
  let obj = tmp / "tu.o"
  # Qt 6.11's qyieldcpu.h calls the ARM `__yield` intrinsic, which current Apple
  # clang flags as an implicit declaration (-Werror by default). The real build
  # downgrades this (config.nims). We mirror it here so the test isolates .pc
  # include-path resolution rather than re-policing this compiler-flag policy.
  let compat = "-Wno-error=implicit-function-declaration"
  let cmd = compiler & " " & extraArgs & " " & cflags & " " & compat &
    " -std=gnu++17 -fPIC -c " & quoteShell(tu) & " -o " & quoteShell(obj)
  let (outp, code) = execCmdEx(cmd)
  result = (code == 0, outp)

proc kitPrefix(version, kit: string): string =
  let base = getEnv("QT_KITS_DIR", getHomeDir() / "Qt" / version)
  base / kit

proc pcDirFor(version, kit: string): string =
  repo / version / kit / "lib" / "pkgconfig"

proc hasCommittedTree(version, kit: string): bool =
  let d = pcDirFor(version, kit)
  dirExists(d) and (fileExists(d / "Qt6Core.pc") or
                    fileExists(d / ("Qt6Core_" & "arm64-v8a") & ".pc"))

# Resolve a committed cflags set and compile; shared assertion body.
proc runCompileCheck(version, kit, realPrefix, arch, compiler, extraArgs: string) =
  let (cok, flags) = wrapperCflags(pcDirFor(version, kit), realPrefix, arch)
  check cok
  check flags.len > 0
  # a resolved include dir must actually exist on disk (catches bad placeholder)
  check (realPrefix / "include").dirExists or (realPrefix / "lib").dirExists
  let (ok, output) = compileTU(compiler, extraArgs, flags)
  if not ok:
    echo "compile failed for ", kit, " (", compiler, "):\n", output
  check ok

const VERSION = "6.11.0"

suite "committed .pc compile":

  test "macos (clang++)":
    when not defined(macosx):
      skip()
    else:
      let prefix = kitPrefix(VERSION, "macos")
      if not hasCommittedTree(VERSION, "macos") or not dirExists(prefix) or
         findExe("clang++").len == 0:
        skip()
      else:
        runCompileCheck(VERSION, "macos", prefix, "", "clang++", "")

  test "ios device + simulator (xcrun clang++)":
    when not defined(macosx):
      skip()
    else:
      let prefix = kitPrefix(VERSION, "ios")
      if not hasCommittedTree(VERSION, "ios") or not dirExists(prefix) or
         findExe("xcrun").len == 0:
        skip()
      else:
        let iosTarget = "26"
        # device (arm64) + simulator (x86_64); both read the same committed tree.
        for (sdk, target) in [("iphoneos", "arm64-apple-ios" & iosTarget),
                              ("iphonesimulator", "x86_64-apple-ios" & iosTarget & "-simulator")]:
          let sysroot = execCmdEx("xcrun --sdk " & sdk & " --show-sdk-path").output.strip()
          let extra = "-target " & target & " -isysroot " & quoteShell(sysroot)
          runCompileCheck(VERSION, "ios", prefix, "", "xcrun --sdk " & sdk & " clang++", extra)

  test "android arm64 (NDK clang++)":
    let ndk = getEnv("ANDROID_NDK_ROOT")
    let prefix = kitPrefix(VERSION, "android_arm64_v8a")
    let hostTag = when defined(macosx): "darwin-x86_64"
                  elif defined(linux): "linux-x86_64"
                  else: ""
    let clang = if ndk.len > 0 and hostTag.len > 0:
                  ndk / "toolchains" / "llvm" / "prebuilt" / hostTag / "bin" / "clang++"
                else: ""
    if not hasCommittedTree(VERSION, "android_arm64_v8a") or not dirExists(prefix) or
       clang.len == 0 or not fileExists(clang):
      skip()
    else:
      let sysroot = ndk / "toolchains" / "llvm" / "prebuilt" / hostTag / "sysroot"
      let extra = "--target=aarch64-linux-android28 --sysroot=" & quoteShell(sysroot)
      runCompileCheck(VERSION, "android_arm64_v8a", prefix, "arm64-v8a", quoteShell(clang), extra)

suite "committed iOS .pc trees":
  test "Qt6Multimedia requires the modules its headers include":
    let pc = readFile(repo / "6.11.0" / "ios" / "lib" / "pkgconfig" / "Qt6Multimedia.pc")
    var requires = ""
    for line in pc.splitLines:
      if line.startsWith("Requires:"):
        requires = line
    for dep in ["Qt6Core", "Qt6Gui", "Qt6Network"]:
      check dep in requires.splitWhitespace
