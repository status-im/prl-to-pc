# qt-pkgconfig.mk — zero-config drop-in for consuming Qt via pkg-config in a seaqt
# build. Just `include` it; there is nothing to configure. The only requirements
# are `qmake` and `nim` (or `nimble`) on PATH.
#
# It picks one of two modes automatically, at make PARSE time, and re-decides on
# every invocation — so switching Kits via QMAKE needs no cleaning:
#
#   System mode     The active Kit already ships usable pkg-config metadata. Its
#                   own `pkgconfig` dir is prepended to PKG_CONFIG_PATH and the
#                   system `pkg-config` is used as-is. Nothing is built, PATH is
#                   left untouched, no prefix-override env is exported, and
#                   `qt-pkgconfig` (plus the tools/generate targets) are no-ops.
#
#   Generated mode  The fallback for Kits whose .pc are missing or carry a Broken
#                   prefix. It:
#                     1. builds the pkg-config Wrapper + the prl_to_pc generator
#                        into QT_PC_BUILD_DIR (default <this-dir>/.pcwrap/;
#                        consumers of a read-only store copy override it);
#                     2. ships, and auto-generates when missing, the committed
#                        relocatable Qt .pc tree for the active Kit under
#                        <this-dir>/<version>/<kit>/lib/pkgconfig;
#                     3. exports the env seaqt's gorge("pkg-config ...") needs at
#                        nim-compile time (PKG_CONFIG_PATH + the Wrapper on PATH,
#                        plus an INTERNAL prefix override so the relocatable
#                        @@QT_PREFIX@@ placeholder resolves to the real Kit).
#
# The Probe is the sole authority for the choice (no override knob, no version
# tables): with the Kit's `pkgconfig` dir (= `qmake -query QT_INSTALL_LIBS`/
# pkgconfig) prepended to PKG_CONFIG_PATH, `pkg-config --variable=libdir Qt6Core`
# must string-equal `qmake -query QT_INSTALL_LIBS` exactly. Pass → System mode;
# any failure (no pkg-config on PATH, no Qt6Core, or a Broken prefix whose libdir
# differs) → Generated mode. Only Qt6Core is probed — deliberately simple; a
# missing module in an otherwise-correct Kit surfaces later as a normal pkg-config
# error at nim-compile time. A one-line $(info ...) reports the chosen mode and
# reason in both modes.
#
# To target a specific Kit, set the standard QMAKE variable (defaults to `qmake`
# on PATH) — that is the ONLY input, and the desktop/mobile Makefiles already set
# it.
#
# Outputs the includer may use (identical in shape across both modes):
#   QT_PCFILEDIR     dir holding this Kit's .pc files —
#                      System mode:    the Kit's own `pkgconfig` dir
#                      Generated mode: the committed .pc tree for the Kit
#   QT_PC_PKGCONFIG  the pkg-config to invoke —
#                      System mode:    `pkg-config` (the system tool, by command
#                                      name, resolved off PATH at use time)
#                      Generated mode: the built Wrapper (= QT_PC_WRAPPER)
#   QT_PC_PREFIX     the real Qt install prefix (from qmake)
#   QT_PC_GENERATOR  path to the built prl_to_pc generator (Generated mode only)
# Targets (valid in both modes; no-ops in System mode):
#   qt-pkgconfig           (aggregate) ready-to-build — add as an order-only
#                          prerequisite of your nim build. System mode: no-op.
#                          Generated mode: Wrapper built + this Kit's .pc present.
#   qt-pkgconfig-tools     build both executables (Generated mode only).
#   qt-pkgconfig-generate  force (re)generate this Kit's .pc tree (Qt bump); commit
#                          it (Generated mode only).

ifndef QT_PKGCONFIG_MK_INCLUDED
QT_PKGCONFIG_MK_INCLUDED := 1

# This file's own directory = the prl-to-pc root (committed .pc trees + src/).
QT_PC_SELF_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Only external requirements: qmake + nim/nimble on PATH.
QMAKE ?= qmake
QT_PC_NIM ?= nim

# Derive the kit from qmake — no caller configuration.
QT_PC_PREFIX := $(shell $(QMAKE) -query QT_INSTALL_PREFIX)
ifeq ($(strip $(QT_PC_PREFIX)),)
 $(error qt-pkgconfig.mk: '$(QMAKE) -query QT_INSTALL_PREFIX' produced nothing — is qmake on PATH?)
endif
QT_PC_KIT := $(notdir $(QT_PC_PREFIX))
QT_PC_VER := $(notdir $(patsubst %/,%,$(dir $(QT_PC_PREFIX))))

# Windows toolchains: PKG_CONFIG_PATH uses ';' and the built tools take '.exe'.
ifeq ($(OS),Windows_NT)
 QT_PC_EXE := .exe
 QT_PC_PATHSEP := ;
else
 QT_PC_EXE :=
 QT_PC_PATHSEP := :
endif

# Android single-arch kits suffix their libs/.pc (libQt6Core_arm64-v8a.so ->
# Qt6Core_arm64-v8a.pc); the wrapper appends this ABI to bare module names so
# seaqt's `pkg-config Qt6Core` resolves. Derived from the kit name, never configured.
ifeq ($(QT_PC_KIT),android_arm64_v8a)
 QT_PC_ARCH := arm64-v8a
else ifeq ($(QT_PC_KIT),android_armv7)
 QT_PC_ARCH := armeabi-v7a
else ifeq ($(QT_PC_KIT),android_x86_64)
 QT_PC_ARCH := x86_64
else ifeq ($(QT_PC_KIT),android_x86)
 QT_PC_ARCH := x86
else
 QT_PC_ARCH :=
endif

# --- the Probe: choose System vs Generated mode at parse time ----------------
# Derive the Kit's own pkgconfig dir from qmake, then ask the system pkg-config
# for Qt6Core's libdir with that dir prepended to PKG_CONFIG_PATH. The env prefix
# lives INSIDE the $(shell) invocation, scoped to the probe command only — it is
# never leaked into the real exports below. stderr is redirected so pkg-config
# warnings/errors never reach the terminal. The libdir must string-equal qmake's
# QT_INSTALL_LIBS exactly: comparing the value (not merely `--exists`) is what
# rejects a wrong Kit — e.g. a distro Qt in /usr would satisfy `--exists` even
# when QMAKE points elsewhere.
QT_PC_LIBS         := $(shell $(QMAKE) -query QT_INSTALL_LIBS)
QT_PC_KIT_PCDIR    := $(QT_PC_LIBS)/pkgconfig
# Parse-time wildcard: does the Kit ship any Qt6Core .pc in its own pkgconfig dir?
# Covers both the bare name (desktop) and the android arch-suffixed name (e.g.
# Qt6Core_arm64-v8a.pc).  Used below to distinguish "kit ships no .pc" from a
# "Broken prefix" kit that does ship one but with a build-farm libdir.
QT_PC_KIT_HAS_PC   := $(wildcard $(QT_PC_KIT_PCDIR)/Qt6Core.pc $(QT_PC_KIT_PCDIR)/Qt6Core_*.pc)
QT_PC_PROBE_LIBDIR := $(shell PKG_CONFIG_PATH="$(QT_PC_KIT_PCDIR)$(QT_PC_PATHSEP)$(PKG_CONFIG_PATH)" pkg-config --variable=libdir Qt6Core 2>/dev/null)

ifeq ($(strip $(QT_PC_PROBE_LIBDIR)),)
 # Empty output: pkg-config missing/unusable, OR kit ships no Qt6Core.pc and no ambient one.
 QT_PC_MODE   := generated
 ifeq ($(strip $(QT_PC_KIT_HAS_PC)),)
  QT_PC_REASON := generated mode: kit ships no Qt6Core.pc in $(QT_PC_KIT_PCDIR)
 else
  QT_PC_REASON := generated mode: kit ships Qt6Core.pc but probe got no answer (pkg-config missing or unusable)
 endif
else ifeq ($(QT_PC_PROBE_LIBDIR),$(QT_PC_LIBS))
 QT_PC_MODE   := system
 QT_PC_REASON := system mode: Qt6Core.pc libdir matches qmake QT_INSTALL_LIBS
else
 # Qt6Core.pc found but its libdir points elsewhere.  Use the parse-time wildcard
 # to distinguish a Kit that ships NO own .pc (mobile/embedded — the probe found
 # an ambient one, e.g. brew Qt) from a Kit that ships one with a Broken prefix.
 QT_PC_MODE   := generated
 ifeq ($(strip $(QT_PC_KIT_HAS_PC)),)
  QT_PC_REASON := generated mode: kit ships no Qt6Core.pc in $(QT_PC_KIT_PCDIR)
 else
  QT_PC_REASON := generated mode: Qt6Core.pc libdir mismatch (broken prefix)
 endif
endif

$(info qt-pkgconfig.mk: $(QT_PC_REASON))

ifeq ($(QT_PC_MODE),system)
# ===== System mode ==========================================================
# Trust the Kit's own .pc plus the system pkg-config. Build nothing, touch no
# PATH, export no prefix override / arch.
QT_PCFILEDIR    := $(QT_PC_KIT_PCDIR)
QT_PC_PKGCONFIG := pkg-config

.PHONY: qt-pkgconfig qt-pkgconfig-tools qt-pkgconfig-generate
qt-pkgconfig qt-pkgconfig-tools qt-pkgconfig-generate:
	@:

# Prepend the Kit's pkgconfig dir to PKG_CONFIG_PATH; PATH stays untouched.
ifeq ($(strip $(PKG_CONFIG_PATH)),)
 export PKG_CONFIG_PATH := $(QT_PCFILEDIR)
else
 export PKG_CONFIG_PATH := $(QT_PCFILEDIR)$(QT_PC_PATHSEP)$(PKG_CONFIG_PATH)
endif

else
# ===== Generated mode =======================================================
# Bit-for-bit the original behaviour: Wrapper build, committed-tree lookup,
# auto-generation, Android ABI suffix, PATH prepend, prefix-override export.

QT_PCFILEDIR := $(QT_PC_SELF_DIR)/$(QT_PC_VER)/$(QT_PC_KIT)/lib/pkgconfig
# Is this kit's committed .pc tree already present? Decided at PARSE time (matches both
# bare Qt6Core.pc and the android arch-suffixed Qt6Core_<abi>.pc) so the generator is
# only pulled in when generation is actually needed — never on a normal build.
QT_PC_HAVE_PC := $(wildcard $(QT_PCFILEDIR)/Qt6Core.pc $(QT_PCFILEDIR)/Qt6Core_*.pc)

# Where the wrapper + generator executables are built. Consumer-overridable
# (set QT_PC_BUILD_DIR before including this file): when this repo is consumed
# as a READ-ONLY nimble store copy, in-package writes are forbidden — the
# consumer points the build at its own scratch dir instead. A plain checkout
# keeps the historical in-repo default.
QT_PC_BUILD_DIR ?= $(QT_PC_SELF_DIR)/.pcwrap
QT_PC_WRAPPER   := $(QT_PC_BUILD_DIR)/pkg-config$(QT_PC_EXE)
QT_PC_GENERATOR := $(QT_PC_BUILD_DIR)/prl_to_pc$(QT_PC_EXE)
QT_PC_PKGCONFIG := $(QT_PC_WRAPPER)

# A nimble store copy carries nimblemeta.json at the package root (a git
# checkout never does). Store copies are read-only pinned content: the
# generate path below must never write .pc trees into them.
QT_PC_STORE_COPY := $(wildcard $(QT_PC_SELF_DIR)/nimblemeta.json)

# The generator imports `regex`; auto-detect status-desktop's vendored copies
# (siblings of this submodule) so plain `nim c` builds it offline. When they are
# absent, fall back to the consumer repo's nimble-resolved store paths
# (QT_PC_CONSUMER_PATHS, consumer-overridable; defaults to a nimble.paths two
# levels up, i.e. next to a vendor/ that holds this repo — a store copy's
# consumer must set it to its own nimble.paths explicitly):
# nim DISABLES its default ~/.nimble/pkgs2 search when the compile's cwd
# contains a nimble.lock, so bare `import regex` resolution cannot be relied
# on there — the paths must be explicit. A standalone clone with neither
# still resolves via nim's default nimblepath (`nimble install regex`).
QT_PC_REGEX_SRC := $(QT_PC_SELF_DIR)/../nim-regex/src
QT_PC_CONSUMER_PATHS ?= $(QT_PC_SELF_DIR)/../../nimble.paths
ifneq (,$(wildcard $(QT_PC_REGEX_SRC)))
 QT_PC_GEN_PATHS := --path:$(QT_PC_REGEX_SRC) --path:$(QT_PC_SELF_DIR)/../nim-unicodedb/src
else ifneq (,$(wildcard $(QT_PC_CONSUMER_PATHS)))
 QT_PC_GEN_PATHS := $(shell awk -F'"' '/pkgs2\/(regex|unicodedb)-/{print "--path:" $$2}' $(QT_PC_CONSUMER_PATHS))
else
 QT_PC_GEN_PATHS :=
endif

# --- build the executables (nim on PATH; wrapper is dependency-free) ---------
$(QT_PC_WRAPPER): $(QT_PC_SELF_DIR)/src/pkgconfig_wrapper.nim
	@mkdir -p $(QT_PC_BUILD_DIR)
	$(QT_PC_NIM) c -d:release --hints:off --skipParentCfg:on -o:$@ $<

$(QT_PC_GENERATOR): $(QT_PC_SELF_DIR)/src/prl_to_pc.nim
	@mkdir -p $(QT_PC_BUILD_DIR)
	$(QT_PC_NIM) c -d:release --hints:off --skipParentCfg:on $(QT_PC_GEN_PATHS) -o:$@ $<

.PHONY: qt-pkgconfig-tools
qt-pkgconfig-tools: $(QT_PC_WRAPPER) $(QT_PC_GENERATOR)

# --- generate the committed .pc tree ----------------------------------------
# Builds the generator (only here) and (re)creates this kit's committed .pc tree.
# Used manually on a Qt version bump (commit the result) and as the auto path below
# when the tree is missing. Because the generator is built only in this target, a
# normal build (tree present) never compiles it.
# The .pc tree is COMMITTED CONTENT of this repo: when this file runs from a
# read-only nimble store copy, generation must refuse instead of scribbling on
# pinned content — new kits are added from a real checkout and committed.
.PHONY: qt-pkgconfig-generate
ifneq (,$(QT_PC_STORE_COPY))
qt-pkgconfig-generate:
	@echo "qt-pkgconfig.mk ERROR: this prl-to-pc copy is a read-only nimble store copy —" >&2; \
	 echo "refusing to generate a Qt .pc tree into it (kit '$(QT_PC_KIT)', $(QT_PCFILEDIR))." >&2; \
	 echo "Develop prl-to-pc (in status-desktop: 'nim develop status.nims prl-to-pc'), run" >&2; \
	 echo "'make qt-pkgconfig-generate' against the checkout, and commit the new tree upstream." >&2; \
	 exit 1
else
qt-pkgconfig-generate: $(QT_PC_GENERATOR)
	@echo "[prl-to-pc] generating Qt .pc for '$(QT_PC_KIT)' from $(QT_PC_PREFIX)"
	"$(QT_PC_GENERATOR)" generate "$$($(QMAKE) -query QT_INSTALL_LIBS)" "$(QT_PC_SELF_DIR)"
endif

# Aggregate prerequisite for the nim build: ensure the wrapper, plus this kit's .pc.
# The .pc dependency is added ONLY when the committed tree is absent (decided at parse
# time via QT_PC_HAVE_PC), so the common case pulls in just the wrapper and the
# generator is never built or even considered.
.PHONY: qt-pkgconfig
ifeq (,$(QT_PC_HAVE_PC))
qt-pkgconfig: $(QT_PC_WRAPPER) qt-pkgconfig-generate
else
qt-pkgconfig: $(QT_PC_WRAPPER)
endif

# --- export the pkg-config environment (all internal; nothing for the caller) -
export PKG_CONFIG_PREFIX_OVERRIDE := Qt*=$(QT_PC_PREFIX)
ifneq ($(strip $(QT_PC_ARCH)),)
 export PKG_CONFIG_ARCH := $(QT_PC_ARCH)
endif
ifeq ($(strip $(PKG_CONFIG_PATH)),)
 export PKG_CONFIG_PATH := $(QT_PCFILEDIR)
else
 export PKG_CONFIG_PATH := $(QT_PCFILEDIR)$(QT_PC_PATHSEP)$(PKG_CONFIG_PATH)
endif
export PATH := $(QT_PC_BUILD_DIR):$(PATH)

endif # QT_PC_MODE

endif # QT_PKGCONFIG_MK_INCLUDED
