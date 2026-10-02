#!/bin/bash
# Build DXMT (https://github.com/3Shain/dxmt) from source: Direct3D 10/11 on Metal, as Wine builtin DLLs.
#
# DXMT has published no release since v0.80, so the revision packaged here is built from the main branch.
# The result has the layout of a DXMT release archive and goes to <work>/build/dxmt, where
# the packaging step (it is not among the published build scripts) takes it from:
#   x86_64-windows/  d3d11.dll dxgi.dll d3d10core.dll winemetal.dll nvapi64.dll nvngx.dll
#   i386-windows/    d3d11.dll dxgi.dll d3d10core.dll winemetal.dll
#   x86_64-unix/     winemetal.so (the Metal side; it contains the shader converter and LLVM)
#   licenses/        dxmt/ and llvm/: the licence texts that have to travel with these binaries
#   VERSION          describe=, commit=, llvm=, source=
#
# DXMT releases up to v0.80 were MIT; everything after v0.80 is LGPL-2.1-or-later. It is built here without
# any change to its source. Whoever passes the binaries on has to offer that source with them: the source
# stage writes it as one archive, to be published next to the disk images.
#
# Usage: bash scripts/build-dxmt.sh <stage>
#   fetch    clone DXMT with its submodules and check out DXMT_REF
#   llvm     build the LLVM static libraries DXMT links (x86_64; a few minutes on a recent Mac, much longer on
#            older ones; needed once)
#   build    cross-compile the 64-bit and the 32-bit DLLs and winemetal.so with Meson
#   install  put the result into <work>/build/dxmt (an existing one is renamed), with the licence texts and VERSION
#   verify   check the files, their types and dependencies, that they were built from unchanged sources,
#            and that no build path ended up in them
#   all      the five stages above, in order
#   source   write <work>/dist/dxmt-<git describe>-src.tar.gz: the checked-out DXMT sources with their
#            submodules (needs only the fetch stage; not part of "all"; the packaging stops without it)
#
# The work directory must be outside your home directory. Xcode's Metal compiler writes the absolute path of
# every shader source into winemetal.so and cannot be told to rewrite it; below the home directory that path
# contains your user name. fetch, llvm, build and all stop before doing anything when that is the case.
#
# Environment:
#   SSFPLAY_WORK    work directory (default: <repo>/work)
#   SSFPLAY_ALLOW_HOME_PATHS
#                   1 = build in a work directory below the home directory all the same. The result is for
#                   this Mac only: winemetal.so then contains your user name. The packaging refuses
#                   such a build unless the variable is set there as well.
#   SSFPLAY_JOBS    parallel compile jobs (default: number of CPUs)
#   DXMT_REF        DXMT revision to build: a commit, a tag or a branch (default: the commit pinned below)
#   DXMT_LLVM_TAG   llvm-project tag of the static libraries (default: llvmorg-15.0.7)
#   DEVELOPER_DIR   Xcode developer directory (default: the selected one if it is a full Xcode, else
#                   /Applications/Xcode.app, else /Applications/Xcode-beta.app)
#
# Before running: scripts/setup-macports.sh (llvm-mingw, the PE cross-compiler) and scripts/build-wine.sh
# (DXMT links Wine's import libraries and its Unix libraries, and marks its DLLs with winebuild). The fetch
# and llvm stages need neither.
#
# Build tools: meson 1.3 or newer, ninja, and cmake 3.27 or newer. They are taken from PATH when all three
# are there; otherwise, when nix is installed, from a one-off `nix shell` that installs nothing.
# A full Xcode with its Metal toolchain: DXMT compiles its built-in shaders with `xcrun -sdk macosx metal`.
# Recent Xcode versions ship that toolchain as a separate component:
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail

usage() {
  echo "Usage: bash $0 fetch|llvm|build|install|verify|all|source"
}

fail() { echo "[FAIL] $*" >&2; exit 1; }

STAGE="${1:-}"
case "$STAGE" in
  fetch|llvm|build|install|verify|all|source) ;;
  *) usage; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SSFPLAY_WORK:-$ROOT/work}"
case "$WORK" in
  /*) ;;
  *) fail "SSFPLAY_WORK must be an absolute path" ;;
esac
# The path maps below are passed to the compilers as plain words.
no_whitespace() {
  case "$1" in
    *[[:space:]]*) fail "the repository and work paths must not contain whitespace: $1" ;;
  esac
}
no_whitespace "$ROOT"
no_whitespace "$WORK"
/bin/mkdir -p "$WORK"

# The revision to build. A full commit hash pins the content of the source tree.
#   fb4515681daefb789a4d0f403c4bdbca88f3b3de = v0.80-247-gfb45156, main branch, 2026-10-01
# To move to a newer DXMT: run the stages with DXMT_REF=<commit of the main branch, or a release tag>,
# test the result in a game, then change the default here and the date and description above it.
DXMT_REF="${DXMT_REF:-fb4515681daefb789a4d0f403c4bdbca88f3b3de}"
DXMT_URL="https://github.com/3Shain/dxmt"
# DXMT's shader converter writes Metal's shader bitcode with LLVM's own bitcode writer, and that format is
# tied to the LLVM release: it has to be LLVM 15.
LLVM_TAG="${DXMT_LLVM_TAG:-llvmorg-15.0.7}"
LLVM_URL="https://github.com/llvm/llvm-project.git"

BUILD="$WORK/build"
MP="$WORK/macports"
TC="$MP/libexec/llvm-mingw"       # PE cross-compiler, installed by the llvm-mingw port
WINE_TREE="$BUILD/wine"           # installed by scripts/build-wine.sh
SRC="$BUILD/dxmt-src"
LLVM_SRC="$BUILD/dxmt-llvm-src"
LLVM_OBJ="$BUILD/dxmt-llvm-build"
LLVM_DIR="$BUILD/dxmt-llvm"       # installed LLVM: include/ and lib/libLLVM*.a
LLVM_STAMP="$LLVM_DIR/SSFPLAY-LLVM-TAG"
OBJ64="$BUILD/dxmt-build64"
OBJ32="$BUILD/dxmt-build32"
DEST="$BUILD/dxmt"
# Meson wants an absolute install prefix. Nothing is installed there: the files reach the disk through
# DESTDIR, and DXMT does not compile the prefix into anything.
STAGE_PREFIX="/dxmt"
JOBS="${SSFPLAY_JOBS:-$(/usr/sbin/sysctl -n hw.ncpu)}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"
DEV=""

# The files of a DXMT release, by directory.
FILES_W64="d3d11.dll dxgi.dll d3d10core.dll winemetal.dll nvapi64.dll nvngx.dll"
FILES_W32="d3d11.dll dxgi.dll d3d10core.dll winemetal.dll"
# The licence texts that go with the binaries (the packaging copies them into the runtime).
# DXMT: its notice, the notice of the releases up to v0.80 (MIT), the LGPL, and the zlib notice of the code it
# took from DXVK.
# LLVM, linked into winemetal.so: the Apache licence with the LLVM exceptions (the same file holds the older
# University of Illinois licence), and the notices of the regex and BLAKE3 code inside LLVM's support library.
FILES_LIC="dxmt/LICENSE dxmt/LICENSE.OLD dxmt/COPYING.LIB dxmt/dxvk.LICENSE llvm/LICENSE.TXT llvm/COPYRIGHT.regex llvm/BLAKE3-LICENSE"

# The test by which the apps recognise DXMT. When an app switches the graphics layer, it has to tell DXMT's
# d3d11, dxgi and d3d10core in an installed runtime from Wine's own, and it does so by content: d3d11 and
# dxgi import winemetal.dll; d3d10core does not (it only forwards to d3d11.dll), but like the other two it
# contains the name of DXMT's logging variable. The apps and the packaging use this same line.
is_dxmt_dll() { [ -f "$1" ] && LC_ALL=C /usr/bin/grep -aq -e 'winemetal\.dll' -e 'DXMT_LOG_LEVEL' "$1"; }

# The Metal compiler records the absolute path of every shader source in the compiled shader and has no
# option to rewrite it, so the place of the DXMT sources ends up in winemetal.so. Below the home directory
# that is the user's name. The stages that download or compile check this first: finding it out in the
# verify stage, after MacPorts, Wine and LLVM have been built in a directory that cannot be used, is too late.
ALLOW_HOME_PATHS="${SSFPLAY_ALLOW_HOME_PATHS:-0}"
below_home() {  # below_home <path>: is it the home directory or something below it?
  local h="${HOME:-}" hr p pr
  h="${h%/}"
  [ -n "$h" ] || return 1
  hr="$( (cd "$h" 2>/dev/null && pwd -P) || printf '%s' "$h")"
  p="${1%/}"
  pr="$( (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "$p")"
  case "$p/" in "$h"/*|"$hr"/*) return 0 ;; esac
  case "$pr/" in "$h"/*|"$hr"/*) return 0 ;; esac
  return 1
}
need_work_outside_home() {
  local where=""
  if below_home "$WORK"; then where="$WORK"
  elif [ -e "$SRC" ] && below_home "$SRC"; then where="$SRC"
  fi
  [ -n "$where" ] || return 0
  if [ "$ALLOW_HOME_PATHS" = 1 ]; then
    echo "[warning] $where is below your home directory and SSFPLAY_ALLOW_HOME_PATHS=1 is set:"
    echo "          winemetal.so will contain that path, and with it your user name."
    echo "          Use this build on this Mac only; do not pass it on."
    return 0
  fi
  echo "[FAIL] the work directory is below your home directory: $where" >&2
  echo "       DXMT's built-in shaders are compiled by Xcode's Metal compiler. It writes the absolute path of" >&2
  echo "       every shader source into winemetal.so and cannot be told to rewrite it. Built here," >&2
  echo "       winemetal.so would contain ${HOME%/}/... and with it your user name, and the verify stage" >&2
  echo "       would reject it after everything has been compiled." >&2
  echo "       Use a work directory outside the home directory, the same one for every script:" >&2
  echo "         export SSFPLAY_WORK=/Users/Shared/ssf-play-build" >&2
  echo "       MacPorts is configured for the path of its work directory and cannot be moved: if" >&2
  echo "       scripts/setup-macports.sh and scripts/build-wine.sh already ran here, run them again there." >&2
  echo "       For a build that stays on this Mac and is never passed on, set SSFPLAY_ALLOW_HOME_PATHS=1." >&2
  exit 1
}

# Keep build-machine paths out of the binaries. LLVM is built with assertions, and every assertion carries
# __FILE__; DXMT's own messages and the headers of Wine and llvm-mingw add more. The repository and the work
# directory are rewritten to /ssfplay. A directory below the work directory may be a symbolic link to
# another place, and compilers report some paths resolved, so the resolved spellings are mapped as well.
# BUILD_PATHS is what the verify stage looks for afterwards.
PATHMAP=()
BUILD_PATHS=()
map_path() {  # map_path <directory> <neutral name>
  local p q real="$1" covered
  if [ -d "$1" ]; then real="$(cd "$1" && pwd -P)"; fi
  for p in "$1" "$real"; do
    covered=0
    for q in ${BUILD_PATHS[@]+"${BUILD_PATHS[@]}"}; do
      case "$p" in "$q"|"$q"/*) covered=1 ;; esac
    done
    [ "$covered" = 0 ] || continue
    no_whitespace "$p"
    PATHMAP+=("-ffile-prefix-map=$p=$2")
    BUILD_PATHS+=("$p")
  done
}
set_path_maps() {
  PATHMAP=(); BUILD_PATHS=()
  map_path "$ROOT" /ssfplay
  map_path "$WORK" /ssfplay/work
  map_path "$MP" /ssfplay/work/macports
  map_path "$TC" /ssfplay/work/macports/libexec/llvm-mingw
  map_path "$BUILD" /ssfplay/work/build
  map_path "$WINE_TREE" /ssfplay/work/build/wine
  map_path "$SRC" /ssfplay/work/build/dxmt-src
  map_path "$LLVM_SRC" /ssfplay/work/build/dxmt-llvm-src
  map_path "$LLVM_OBJ" /ssfplay/work/build/dxmt-llvm-build
  map_path "$LLVM_DIR" /ssfplay/work/build/dxmt-llvm
  map_path "$OBJ64" /ssfplay/work/build/dxmt-build64
  map_path "$OBJ32" /ssfplay/work/build/dxmt-build32
}

# Run a command with meson, ninja and cmake available.
with_build_tools() {
  if command -v meson >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1 && command -v cmake >/dev/null 2>&1; then
    "$@"
  elif command -v nix >/dev/null 2>&1; then
    nix shell nixpkgs#meson nixpkgs#ninja nixpkgs#cmake -c "$@"
  else
    echo "[FAIL] meson (1.3 or newer), ninja and cmake (3.27 or newer) are needed and not all are in PATH." >&2
    echo "       Install them (the packages are called meson, ninja and cmake in Homebrew, MacPorts and nixpkgs)," >&2
    echo "       or install nix and this script fetches them with a one-off 'nix shell'." >&2
    exit 1
  fi
}

# Run a command in the build environment.
# - env -i keeps the caller's shell environment (other compilers, other package managers) out. Of the build
#   tools only the directories that hold meson, ninja and cmake are kept in PATH.
# - PATH: the system first, so that the Mach-O side is built by /usr/bin/clang, which DEVELOPER_DIR points
#   at the full Xcode (the same compiler and SDK for LLVM and for DXMT). llvm-mingw comes after it: it has
#   a plain "clang" too, and only its <triplet>-prefixed tools are wanted. The directories of the build
#   tools come last: one of them may hold another MinGW (Homebrew's mingw-w64 has the same tool names), and
#   the DLLs must be built by the llvm-mingw that was checked, whose licence texts are the ones packaged.
# - The deployment target is the one Wine is built with.
xbuild() {
  local user="${USER:-$(/usr/bin/id -un)}"
  # shellcheck disable=SC2016  # the inner shell expands these
  with_build_tools /bin/sh -c '
    dirs=""
    for t in meson ninja cmake; do
      d="$(dirname "$(command -v "$t")")"
      case ":$dirs:" in *":$d:"*) ;; *) dirs="$dirs:$d" ;; esac
    done
    user="$1"; tc="$2"; dev="$3"; shift 3
    exec /usr/bin/env -i HOME="$HOME" USER="$user" LOGNAME="$user" TERM="${TERM:-dumb}" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:$tc$dirs" \
      DEVELOPER_DIR="$dev" MACOSX_DEPLOYMENT_TARGET=14.0 "$@"' sh "$user" "$TC/bin" "$DEV" "$@"
}

# The developer directory of a full Xcode. The Command Line Tools are not enough: they have no Metal
# compiler and no xcodebuild.
need_xcode() {
  local d
  [ -z "$DEV" ] || return 0
  for d in "${DEVELOPER_DIR:-}" "$(/usr/bin/xcode-select -p 2>/dev/null || true)" \
           /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
    [ -n "$d" ] || continue
    if [ -x "$d/usr/bin/xcodebuild" ]; then DEV="$d"; return 0; fi
  done
  echo "[FAIL] a full Xcode is needed: DXMT's built-in shaders are compiled with Xcode's Metal compiler," >&2
  echo "       and the Command Line Tools do not have one." >&2
  echo "       Install Xcode, or set DEVELOPER_DIR to the Contents/Developer directory of an installed one." >&2
  exit 1
}

need_metal() {
  need_xcode
  local out
  out="$(DEVELOPER_DIR="$DEV" /usr/bin/xcrun -sdk macosx metal --version 2>&1 || true)"
  if DEVELOPER_DIR="$DEV" /usr/bin/xcrun -sdk macosx -f metallib >/dev/null 2>&1; then
    case "$out" in *"missing Metal Toolchain"*) ;; *) return 0 ;; esac
  fi
  echo "[FAIL] the Metal toolchain is not installed in the Xcode at ${DEV%/Contents/Developer}." >&2
  echo "       DXMT compiles its built-in shaders with 'xcrun -sdk macosx metal' and 'metallib'." >&2
  echo "       The toolchain is a separate component of Xcode, downloaded from Apple. Install it with" >&2
  echo "         DEVELOPER_DIR=$DEV xcodebuild -downloadComponent MetalToolchain" >&2
  echo "       then check with" >&2
  echo "         DEVELOPER_DIR=$DEV xcrun -sdk macosx metal --version" >&2
  echo "       and run this stage again." >&2
  exit 1
}

need_rosetta() {
  /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null \
    || fail "Rosetta 2 is required: softwareupdate --install-rosetta --agree-to-license"
}

need_toolchain() {
  local t
  for t in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-g++ x86_64-w64-mingw32-windres \
           i686-w64-mingw32-gcc i686-w64-mingw32-g++ i686-w64-mingw32-windres; do
    if [ ! -x "$TC/bin/$t" ]; then
      echo "[FAIL] llvm-mingw (the PE cross-compiler) not found: $TC/bin/$t is missing." >&2
      echo "       Run scripts/setup-macports.sh first (stages bootstrap and deps), with the same SSFPLAY_WORK." >&2
      exit 1
    fi
  done
}

need_wine() {
  local f
  for f in bin/winebuild include/wine/windows/windef.h \
           lib/wine/x86_64-windows/libwinecrt0.a lib/wine/x86_64-windows/libntdll.a \
           lib/wine/i386-windows/libwinecrt0.a lib/wine/i386-windows/libntdll.a \
           lib/wine/x86_64-unix/ntdll.so lib/wine/x86_64-unix/winemac.so; do
    if [ ! -e "$WINE_TREE/$f" ]; then
      echo "[FAIL] no usable Wine tree at $WINE_TREE: $f is missing." >&2
      echo "       DXMT needs Wine's headers, import libraries, Unix libraries and winebuild." >&2
      echo "       Run scripts/build-wine.sh first (through the install stage), with the same SSFPLAY_WORK." >&2
      exit 1
    fi
  done
}

need_sources() {
  [ -f "$SRC/meson.build" ] || fail "no DXMT sources at $SRC; run the fetch stage first"
  [ -f "$SRC/include/native/directx/d3d11.h" ] \
    || fail "the submodules of $SRC are not checked out; run the fetch stage again"
}

need_llvm() {
  [ -f "$LLVM_STAMP" ] && [ -f "$LLVM_DIR/lib/libLLVMCore.a" ] \
    || fail "no LLVM static libraries at $LLVM_DIR; run the llvm stage first"
}

# LLVM's licence texts are kept with the installed libraries, because the LLVM sources may be moved away
# after the llvm stage.
llvm_licences() {  # llvm_licences <installed LLVM directory>
  local s="$LLVM_SRC/llvm" f
  for f in LICENSE.TXT lib/Support/COPYRIGHT.regex lib/Support/BLAKE3/LICENSE; do
    [ -f "$s/$f" ] || fail "no $f in $s; the licence texts of LLVM come from its sources"
  done
  /bin/mkdir -p "$1/licenses"
  /bin/cp "$s/LICENSE.TXT" "$1/licenses/LICENSE.TXT"
  /bin/cp "$s/lib/Support/COPYRIGHT.regex" "$1/licenses/COPYRIGHT.regex"
  /bin/cp "$s/lib/Support/BLAKE3/LICENSE" "$1/licenses/BLAKE3-LICENSE"
}

# The commit that DXMT_REF stands for, looked up in the clone without the network. A branch name means the
# branch as the fetch stage last saw it.
pinned_commit() {
  /usr/bin/git -C "$SRC" rev-parse -q --verify "origin/$DXMT_REF^{commit}" 2>/dev/null \
    || /usr/bin/git -C "$SRC" rev-parse -q --verify "$DXMT_REF^{commit}" 2>/dev/null || true
}

# What is built and installed must be the revision that DXMT_REF names, not whatever the source tree was
# left at: the runtime stamp, the source archive and THIRD_PARTY_LICENSES.md all go by that revision.
need_pinned_sources() {
  need_sources
  local want have
  want="$(pinned_commit)"
  have="$(/usr/bin/git -C "$SRC" rev-parse -q --verify HEAD 2>/dev/null || true)"
  [ -n "$want" ] || fail "DXMT_REF=$DXMT_REF is not a commit, tag or branch known in $SRC; run the fetch stage"
  [ "$have" = "$want" ] \
    || fail "$SRC is at ${have:-an unknown revision}, but DXMT_REF=$DXMT_REF is $want. Run the fetch stage (it checks out DXMT_REF), or set DXMT_REF to the revision you mean to build."
}

do_fetch() {
  echo "== fetch: DXMT $DXMT_REF =="
  /bin/mkdir -p "$BUILD"
  local tmp want have
  if [ ! -d "$SRC/.git" ]; then
    [ ! -e "$SRC" ] || fail "$SRC exists but is not a git checkout; rename it and run fetch again"
    # A full clone, not a shallow one: the version DXMT reports is `git describe`, which needs the history
    # back to the last release tag. Cloned next to the final location and renamed, so that an interrupted
    # clone is never taken for the sources.
    tmp="$SRC.cloning"
    if [ -e "$tmp" ]; then /bin/mv "$tmp" "$tmp.old-$STAMP"; fi
    /usr/bin/git clone -q --no-checkout "$DXMT_URL" "$tmp"
    /bin/mv "$tmp" "$SRC"
  fi
  # A commit that is already here needs no network. A tag or a branch name is looked up again.
  case "$DXMT_REF" in
    *[!0-9a-f]*) /usr/bin/git -C "$SRC" fetch -q --tags origin ;;
    *) /usr/bin/git -C "$SRC" cat-file -e "$DXMT_REF^{commit}" 2>/dev/null \
         || /usr/bin/git -C "$SRC" fetch -q --tags origin ;;
  esac
  want="$(pinned_commit)"
  [ -n "$want" ] || fail "DXMT_REF=$DXMT_REF is not a commit, tag or branch of $DXMT_URL"
  have="$(/usr/bin/git -C "$SRC" rev-parse -q --verify HEAD 2>/dev/null || true)"
  if [ "$have" != "$want" ] || [ ! -f "$SRC/meson.build" ]; then
    if [ -f "$SRC/meson.build" ] && [ -n "$(/usr/bin/git -C "$SRC" status --porcelain --untracked-files=no)" ]; then
      fail "$SRC has local changes and is at another revision; rename it and run fetch again"
    fi
    /usr/bin/git -C "$SRC" checkout -q --detach "$want"
  fi
  /usr/bin/git -C "$SRC" submodule --quiet update --init --recursive
  [ -f "$SRC/include/native/directx/d3d11.h" ] || fail "the submodule include/native/directx is empty"
  echo "  $(/usr/bin/git -C "$SRC" describe --always --dirty)  $(/usr/bin/git -C "$SRC" log -1 --format='%H %ci')"
  echo "  licence files: $(cd "$SRC" && /bin/ls LICENSE* COPYING* 2>/dev/null | /usr/bin/tr '\n' ' ')"
  echo "[OK] DXMT sources: $SRC"
}

do_llvm() {
  echo "== llvm: $LLVM_TAG, x86_64 static libraries =="
  if [ -f "$LLVM_STAMP" ] && [ "$(/bin/cat "$LLVM_STAMP")" = "$LLVM_TAG" ] && [ -f "$LLVM_DIR/lib/libLLVMCore.a" ]; then
    # An LLVM installed before the licence texts were kept with it gets them now, from the same sources.
    if [ ! -f "$LLVM_DIR/licenses/LICENSE.TXT" ]; then
      [ "$(/usr/bin/git -C "$LLVM_SRC" describe --tags --exact-match 2>/dev/null || true)" = "$LLVM_TAG" ] \
        || fail "$LLVM_DIR has no licence texts and $LLVM_SRC is not at $LLVM_TAG; rename $LLVM_DIR and run llvm again"
      llvm_licences "$LLVM_DIR"
      echo "  licence texts added to $LLVM_DIR/licenses"
    fi
    echo "[SKIP] $LLVM_DIR already holds $LLVM_TAG (rename that directory to build it again)"
    return 0
  fi
  need_xcode
  need_rosetta   # the build runs its own x86_64 llvm-tblgen
  /bin/mkdir -p "$BUILD"
  local tmp have
  if [ ! -d "$LLVM_SRC/.git" ]; then
    [ ! -e "$LLVM_SRC" ] || fail "$LLVM_SRC exists but is not a git checkout; rename it and run llvm again"
    tmp="$LLVM_SRC.cloning"
    if [ -e "$tmp" ]; then /bin/mv "$tmp" "$tmp.old-$STAMP"; fi
    # advice.detachedHead=false: checking out a tag is intended.
    /usr/bin/git -c advice.detachedHead=false clone -q --depth 1 --branch "$LLVM_TAG" "$LLVM_URL" "$tmp"
    /bin/mv "$tmp" "$LLVM_SRC"
  fi
  have="$(/usr/bin/git -C "$LLVM_SRC" describe --tags --exact-match 2>/dev/null || true)"
  [ "$have" = "$LLVM_TAG" ] \
    || fail "$LLVM_SRC is at ${have:-an unknown revision}, not $LLVM_TAG; rename that directory and $LLVM_OBJ, then run llvm again"
  set_path_maps
  # The options are those of DXMT's own CI: static libraries only, no code generator for any target, no
  # tools, assertions on. Added here: the compiler by absolute path, the deployment target, the path maps,
  # and a neutral install prefix (the real destination is given at install time).
  xbuild cmake -S "$LLVM_SRC/llvm" -B "$LLVM_OBJ" -G Ninja \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_INSTALL_PREFIX=/ssfplay/work/build/dxmt-llvm \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
    -DLLVM_ENABLE_ASSERTIONS=On \
    -DLLVM_ENABLE_ZSTD=Off \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="${PATHMAP[*]}" \
    -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23 ${PATHMAP[*]}" \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off \
    -DLLVM_INCLUDE_BENCHMARKS=Off \
    -DBUG_REPORT_URL="$DXMT_URL" \
    -DPACKAGE_VENDOR="DXMT" \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off
  xbuild cmake --build "$LLVM_OBJ" -j "$JOBS"
  tmp="$LLVM_DIR.installing"
  if [ -e "$tmp" ]; then /bin/mv "$tmp" "$tmp.old-$STAMP"; fi
  xbuild cmake --install "$LLVM_OBJ" --prefix "$tmp" >/dev/null
  [ -f "$tmp/lib/libLLVMCore.a" ] || fail "the LLVM install produced no $tmp/lib/libLLVMCore.a"
  [ "$(/usr/bin/lipo -archs "$tmp/lib/libLLVMCore.a")" = x86_64 ] || fail "libLLVMCore.a is not x86_64"
  llvm_licences "$tmp"
  printf '%s\n' "$LLVM_TAG" > "$tmp/SSFPLAY-LLVM-TAG"
  if [ -e "$LLVM_DIR" ]; then
    /bin/mv "$LLVM_DIR" "$LLVM_DIR.bak-$STAMP"
    echo "  previous LLVM renamed to $LLVM_DIR.bak-$STAMP"
  fi
  /bin/mv "$tmp" "$LLVM_DIR"
  echo "[OK] LLVM installed: $LLVM_DIR ($(/usr/bin/du -sh "$LLVM_DIR" | /usr/bin/cut -f1))"
  echo "     $LLVM_SRC and $LLVM_OBJ are not needed any more."
}

# Configure one Meson build directory, or configure it again if it exists.
meson_setup() {  # meson_setup <build dir> <cross file> [options ...]
  local obj="$1" cross="$2" maps reconf=()
  shift 2
  maps="$(IFS=,; printf '%s' "${PATHMAP[*]}")"
  if [ -f "$obj/build.ninja" ]; then reconf=(--reconfigure); fi
  # c_args and cpp_args reach the PE side (llvm-mingw), build.c_args and build.cpp_args the Mach-O side.
  xbuild meson setup ${reconf[@]+"${reconf[@]}"} "$obj" "$SRC" --cross-file "$SRC/$cross" \
    --buildtype release --prefix "$STAGE_PREFIX" --strip \
    -Dwine_install_path="$WINE_TREE" \
    -Dc_args="$maps" -Dcpp_args="$maps" -Dbuild.c_args="$maps" -Dbuild.cpp_args="$maps" \
    "$@"
}

do_build() {
  echo "== build: DXMT $(/usr/bin/git -C "$SRC" describe --always --dirty 2>/dev/null || echo '?'), 64-bit and 32-bit =="
  need_pinned_sources
  need_llvm
  need_toolchain
  need_wine
  need_rosetta   # winebuild is x86_64
  need_metal
  set_path_maps
  # The options are those of DXMT's own release build. The 64-bit build also makes winemetal.so, the only
  # part that links LLVM; the 32-bit DLLs use the same 64-bit winemetal.so at run time.
  meson_setup "$OBJ64" build-win64.txt -Denable_nvapi=true -Denable_nvngx=true -Dnative_llvm_path="$LLVM_DIR"
  xbuild meson compile -C "$OBJ64" -j "$JOBS"
  meson_setup "$OBJ32" build-win32.txt
  xbuild meson compile -C "$OBJ32" -j "$JOBS"
  echo "[OK] build finished"
}

do_install() {
  echo "== install: $DEST =="
  need_pinned_sources
  need_llvm
  need_xcode
  [ -f "$OBJ64/src/d3d11/d3d11.dll" ] && [ -f "$OBJ64/src/winemetal/unix/winemetal.so" ] \
    || fail "no 64-bit build in $OBJ64; run the build stage first"
  [ -f "$OBJ32/src/d3d11/d3d11.dll" ] || fail "no 32-bit build in $OBJ32; run the build stage first"
  [ -f "$LLVM_DIR/licenses/LICENSE.TXT" ] \
    || fail "no licence texts in $LLVM_DIR/licenses; run the llvm stage again (it adds them without rebuilding)"
  local destdir="$BUILD/dxmt-destdir" tree new="$DEST.installing" f
  if [ -e "$destdir" ]; then /bin/mv "$destdir" "$destdir.old-$STAMP"; fi
  xbuild /usr/bin/env DESTDIR="$destdir" meson install -C "$OBJ64" --no-rebuild >/dev/null
  xbuild /usr/bin/env DESTDIR="$destdir" meson install -C "$OBJ32" --no-rebuild >/dev/null
  tree="$destdir$STAGE_PREFIX"
  [ -f "$tree/x86_64-windows/d3d11.dll" ] || fail "meson install produced no $tree/x86_64-windows/d3d11.dll"
  # What a DXMT release archive holds: everything that was installed except the import libraries.
  if [ -e "$new" ]; then /bin/mv "$new" "$new.old-$STAMP"; fi
  /bin/mkdir -p "$new"
  ( cd "$tree" && /usr/bin/tar -cf - --exclude '*.a' . ) | ( cd "$new" && /usr/bin/tar -xf - )
  # The licence texts, taken from the sources that were compiled (see FILES_LIC).
  /bin/mkdir -p "$new/licenses/dxmt" "$new/licenses/llvm"
  for f in LICENSE LICENSE.OLD COPYING.LIB src/util/dxvk.LICENSE; do
    [ -f "$SRC/$f" ] || fail "the DXMT sources have no $f; the licence texts must be looked at again for this revision"
    /bin/cp "$SRC/$f" "$new/licenses/dxmt/$(/usr/bin/basename "$f")"
  done
  /bin/cp "$LLVM_DIR/licenses/LICENSE.TXT" "$LLVM_DIR/licenses/COPYRIGHT.regex" "$LLVM_DIR/licenses/BLAKE3-LICENSE" \
    "$new/licenses/llvm/"
  {
    echo "describe=$(/usr/bin/git -C "$SRC" describe --always --dirty)"
    echo "commit=$(/usr/bin/git -C "$SRC" rev-parse HEAD)"
    echo "llvm=$(/bin/cat "$LLVM_STAMP")"
    echo "source=$DXMT_URL"
  } > "$new/VERSION"
  if [ -e "$DEST" ]; then
    /bin/mv "$DEST" "$DEST.bak-$STAMP"
    echo "  previous tree renamed to $DEST.bak-$STAMP (to roll back, rename it back)"
  fi
  /bin/mv "$new" "$DEST"
  /bin/cat "$DEST/VERSION" | /usr/bin/sed 's/^/  /'
  echo "[OK] installed:"
  ( cd "$DEST" && /usr/bin/find . -type f | /usr/bin/sort | /usr/bin/sed 's|^\./|  |' )
}

do_verify() {
  echo "== verify: $DEST =="
  [ -f "$DEST/VERSION" ] || fail "no DXMT at $DEST; run the install stage first"
  local f t a bad=0 so="$DEST/x86_64-unix/winemetal.so" deps p patterns=() hits desc home_paths=0

  # check_pe <file> <pattern of `file -b`> <what it should be>
  check_pe() {
    if [ ! -f "$DEST/$1" ]; then echo "  [FAIL] $1: missing"; bad=1; return 0; fi
    t="$(/usr/bin/file -b "$DEST/$1")"
    # shellcheck disable=SC2254  # the pattern is meant to be one
    case "$t" in
      $2) ;;
      *) echo "  [FAIL] $1: not $3: $t"; bad=1; return 0 ;;
    esac
    # winebuild --builtin writes this signature into the DOS header. Without it Wine does not treat a DLL
    # in its own library directory as one of its builtin DLLs.
    if ! /usr/bin/head -c 128 "$DEST/$1" | LC_ALL=C /usr/bin/grep -aq 'Wine builtin DLL'; then
      echo "  [FAIL] $1: not marked as a Wine builtin DLL"; bad=1
    fi
  }
  for f in $FILES_W64; do check_pe "x86_64-windows/$f" 'PE32+*x86-64*' "a 64-bit PE file"; done
  for f in $FILES_W32; do check_pe "i386-windows/$f" 'PE32 *[38]86*' "a 32-bit PE file"; done

  # The apps tell DXMT's DLLs from Wine's own by content (is_dxmt_dll above). The test has to hold in both
  # directions for this build: every DXMT DLL is recognised, and none of Wine's own is.
  for a in x86_64-windows i386-windows; do
    for f in d3d11.dll dxgi.dll d3d10core.dll; do
      [ -f "$DEST/$a/$f" ] || continue
      if ! is_dxmt_dll "$DEST/$a/$f"; then
        echo "  [FAIL] $a/$f: contains neither \"winemetal.dll\" nor \"DXMT_LOG_LEVEL\"; the apps would not"
        echo "         recognise it as DXMT. A released app cannot be changed, so a DXMT for an installed runtime"
        echo "         has to keep one of the two strings. For a new release, find a mark that this DXMT revision"
        echo "         has and change is_dxmt_dll here, in the apps and in the packaging alike."
        bad=1
      fi
    done
    for f in d3d10.dll d3d10core.dll d3d11.dll d3d12.dll dxgi.dll; do
      if is_dxmt_dll "$WINE_TREE/lib/wine/$a/$f"; then
        echo "  [FAIL] Wine's own $a/$f in $WINE_TREE would be taken for a DXMT DLL"; bad=1
      fi
    done
  done

  # DXMT is passed on as built from unchanged sources: the source archive and THIRD_PARTY_LICENSES.md say so.
  # git describes a tree with local changes as <revision>-dirty, and the install stage records that.
  desc="$(/usr/bin/sed -n 's/^describe=//p' "$DEST/VERSION" | /usr/bin/head -1)"
  case "$desc" in
    "") echo "  [FAIL] VERSION has no describe= line; run the install stage again"; bad=1 ;;
    *-dirty)
      echo "  [FAIL] this DXMT was built from sources with local changes ($desc)."
      echo "         To build the published revision: undo the changes (git -C $SRC status shows them), then run"
      echo "         build and install again. To pass on a DXMT you changed: commit the change, build that commit"
      echo "         (DXMT_REF), and publish your changed source with it, as the LGPL asks."
      bad=1 ;;
  esac

  if [ ! -f "$so" ]; then
    echo "  [FAIL] x86_64-unix/winemetal.so: missing"; bad=1
  else
    t="$(/usr/bin/file -b "$so")"
    case "$t" in
      "Mach-O 64-bit"*x86_64*) ;;
      *) echo "  [FAIL] x86_64-unix/winemetal.so: not an x86_64 Mach-O library: $t"; bad=1 ;;
    esac
    # Wine's own two libraries are found through @rpath next to winemetal.so; everything else must be part
    # of macOS, or the library would not load on another Mac.
    deps="$(/usr/bin/otool -L "$so" | /usr/bin/sed 1d | /usr/bin/awk '{ print $1 }' \
      | /usr/bin/grep -vE '^(/usr/lib/|/System/Library/|@rpath/(winemetal|winemac|ntdll)\.so$)' || true)"
    if [ -n "$deps" ]; then
      echo "  [FAIL] x86_64-unix/winemetal.so depends on libraries that are not part of macOS:"
      printf '%s\n' "$deps" | /usr/bin/sed 's/^/         /'
      bad=1
    fi
  fi

  # The binaries may only be passed on together with these texts.
  for f in $FILES_LIC; do
    if [ ! -s "$DEST/licenses/$f" ]; then echo "  [FAIL] licenses/$f: missing"; bad=1; fi
  done

  # No path of this machine: the repository, the work directory, the home directory, the nix store.
  set_path_maps
  for p in "${BUILD_PATHS[@]}" /nix/store; do patterns+=(-e "$p"); done
  case "${HOME:-/}" in /|"") ;; *) patterns+=(-e "$HOME") ;; esac
  # One kind of path cannot be mapped: the Metal compiler records the absolute path of every shader source
  # in the compiled shader and has no option to rewrite it (-ffile-prefix-map and -fdebug-prefix-map are
  # accepted and ignored). Those paths, which end in .metal, are tolerated unless they are below the home
  # directory; any other path of this machine is an error.
  local occ shader other
  hits="$(LC_ALL=C /usr/bin/grep -rlaF "${patterns[@]}" "$DEST" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    while IFS= read -r f; do
      occ="$(LC_ALL=C /usr/bin/grep -aoF "${patterns[@]}" "$f" | /usr/bin/sort -u | /usr/bin/sed 's/[][\.*^$]/\\&/g' \
        | while IFS= read -r p; do LC_ALL=C /usr/bin/grep -ao "${p}[A-Za-z0-9_./+-]*" "$f"; done \
        | /usr/bin/sed 's/\(\.metal\).*$/\1/' | /usr/bin/sort -u)"   # the next string follows without a separator
      shader="$(printf '%s\n' "$occ" | /usr/bin/grep -E '\.metal$' || true)"
      other="$(printf '%s\n' "$occ" | /usr/bin/grep -vE '\.metal$' || true)"
      if [ -n "$other" ]; then
        echo "  [FAIL] ${f#"$DEST"/} contains a path of this machine:"
        printf '%s\n' "$other" | /usr/bin/head -5 | /usr/bin/sed 's/^/           /'
        echo "         Something was compiled without the path maps. Rename $LLVM_DIR, $OBJ64 and $OBJ32,"
        echo "         then run the llvm, build and install stages again."
        bad=1
      fi
      if [ -n "$shader" ]; then
        case "${HOME:-/}" in /|"") p="" ;; *) p="$(printf '%s\n' "$shader" | /usr/bin/grep -F "$HOME/" || true)" ;; esac
        if [ -n "$p" ]; then
          if [ "$ALLOW_HOME_PATHS" = 1 ]; then
            echo "  [warning] ${f#"$DEST"/} contains shader source paths below your home directory, for example:"
            printf '%s\n' "$p" | /usr/bin/head -1 | /usr/bin/sed 's/^/           /'
            echo "         Accepted because SSFPLAY_ALLOW_HOME_PATHS=1 is set. Do not pass this build on."
            home_paths=1
          else
            echo "  [FAIL] ${f#"$DEST"/} contains shader source paths below your home directory, for example:"
            printf '%s\n' "$p" | /usr/bin/head -1 | /usr/bin/sed 's/^/           /'
            echo "         The Metal compiler records these paths and cannot rewrite them. For binaries that are"
            echo "         passed on, use a work directory outside the home directory, for example"
            echo "         SSFPLAY_WORK=/Users/Shared/ssf-play-build, and build DXMT there."
            echo "         For a build that stays on this Mac, set SSFPLAY_ALLOW_HOME_PATHS=1."
            bad=1
          fi
        else
          echo "  [note] ${f#"$DEST"/} contains the paths of DXMT's shader sources ($(printf '%s\n' "$shader" | /usr/bin/grep -c .) files below"
          echo "         $(printf '%s\n' "$shader" | /usr/bin/head -1 | /usr/bin/sed 's|/src/.*||')); the Metal compiler records them and cannot rewrite them"
        fi
      fi
    done <<EOF_HITS
$hits
EOF_HITS
  fi

  [ "$bad" = 0 ] || fail "verify failed"
  /bin/cat "$DEST/VERSION" | /usr/bin/sed 's/^/  /'
  ( cd "$DEST" && for f in x86_64-windows/*.dll i386-windows/*.dll x86_64-unix/winemetal.so; do
      printf '  %10d  %s\n' "$(/usr/bin/stat -f%z "$f")" "$f"
    done )
  echo "  all files and licence texts present, PE files marked as Wine builtin and recognised as DXMT by content,"
  echo "  built from unchanged sources, winemetal.so depends on macOS only,"
  echo "  no build path other than those of the shader sources"
  if [ "$home_paths" = 1 ]; then
    echo "[OK] verify passed for use on this Mac only: winemetal.so contains paths below your home directory."
    echo "     The packaging refuses this build unless SSFPLAY_ALLOW_HOME_PATHS=1 is set there as well."
    return 0
  fi
  echo "[OK] verify passed. Next: bash scripts/build-dxmt.sh source (the source archive that is published"
  echo "     with the disk images), then the packaging."
}

# The complete DXMT source as one file. DXMT is LGPL: its source has to be offered in the same place as the
# binaries, and a link to three upstream repositories does not stay valid by itself.
#
# Left out of the archive: external/nvapi/docs. Those are documentation files of NVIDIA's NVAPI SDK (a
# compiled help file, a Word document, a PDF). Unlike the headers and the sample code of that submodule, which
# carry the MIT licence in every file, they come with no licence statement, so nothing says that they may be
# passed on. They are not source of DXMT either: the build reads only the headers at the top of
# external/nvapi. SOURCE.txt in the archive names the omitted files and where they are published.
SOURCE_OMIT='external/nvapi/docs/'
do_source() {
  echo "== source: archive of the DXMT sources =="
  need_sources
  local desc commit name stage out list omitted n t
  # The archive must be exactly what upstream published: no local change in DXMT or in a submodule.
  # (A changed DXMT is a modified LGPL work; its files would need notices of the change and its date.)
  [ -z "$(/usr/bin/git -C "$SRC" status --porcelain --untracked-files=no --ignore-submodules=untracked)" ] \
    || fail "$SRC has local changes or a submodule at another commit; the archive is for the unmodified sources"
  desc="$(/usr/bin/git -C "$SRC" describe --always)"
  commit="$(/usr/bin/git -C "$SRC" rev-parse HEAD)"
  # A commit made in this clone is not what upstream published either, however clean the tree is.
  [ -n "$(/usr/bin/git -C "$SRC" for-each-ref --count=1 --contains "$commit" refs/remotes/origin)" ] \
    || fail "commit $commit is in no branch of $DXMT_URL as last fetched; the archive is for sources that upstream published"
  name="dxmt-$desc-src"
  stage="$BUILD/dxmt-source"
  out="$WORK/dist/$name.tar.gz"
  if [ -e "$stage" ]; then /bin/mv "$stage" "$stage.old-$STAMP"; fi
  /bin/mkdir -p "$stage/$name/dxmt" "$WORK/dist"
  # Every file git tracks, in DXMT and in its submodules, and nothing else (no .git, no build output),
  # without the files below SOURCE_OMIT.
  list="$stage/files"
  omitted="$stage/omitted"
  /usr/bin/git -C "$SRC" ls-files -z --recurse-submodules | LC_ALL=C /usr/bin/grep -z -v "^$SOURCE_OMIT" > "$list"
  /usr/bin/git -C "$SRC" ls-files --recurse-submodules | LC_ALL=C /usr/bin/grep "^$SOURCE_OMIT" > "$omitted" || true
  n="$(/usr/bin/tr -cd '\0' < "$list" | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
  [ "$n" -gt 0 ] || fail "git lists no files in $SRC"
  # What the build needs must not be among the omitted files: the headers of both submodules are still there.
  for t in external/nvapi/nvapi.h include/native/directx/d3d11.h; do
    LC_ALL=C /usr/bin/grep -z -q -x "$t" "$list" \
      || fail "the file list lacks $t, a header of a submodule; run the fetch stage again"
  done
  ( cd "$SRC" && /usr/bin/tar -cf - --null -T "$list" ) | ( cd "$stage/$name/dxmt" && /usr/bin/tar -xf - )
  {
    echo "DXMT source"
    echo
    echo "dxmt/ holds the source of DXMT (Direct3D 10/11 on Metal) as published by its authors:"
    echo "  $DXMT_URL"
    echo "  commit $commit"
    echo "  git describe: $desc"
    echo "with the submodules at the commits which that revision pins:"
    # shellcheck disable=SC2016  # git expands these for each submodule
    /usr/bin/git -C "$SRC" submodule foreach --quiet --recursive \
      'echo "  dxmt/$displaypath  $(git config --get remote.origin.url)  commit $(git rev-parse HEAD)"'
    echo "No file in dxmt/ was changed. Licence: LGPL-2.1-or-later, see dxmt/LICENSE and dxmt/COPYING.LIB."
    if [ -s "$omitted" ]; then
      echo
      echo "Left out: the documentation files of NVIDIA's NVAPI SDK in the submodule external/nvapi:"
      /usr/bin/sed 's/^/  /' "$omitted"
      echo "They are not used to build DXMT and, unlike the headers and samples of that submodule, carry no"
      echo "licence statement. They are in the nvapi repository named above, at that commit."
    fi
    echo
    echo "This is the source of the DXMT files in every SSF Play runtime whose VERSION-ssfplay says"
    echo "  dxmt=$desc"
    echo "Those files were built by scripts/build-dxmt.sh, which holds every build option and also builds the"
    echo "LLVM libraries that DXMT links: $LLVM_URL at the tag $LLVM_TAG, unmodified."
    echo "The script is published with the other build scripts and the patches to Wine:"
    echo "  https://play.ssf.network/source/   (ssf-play-lgpl-sources-<version>.tar.gz, next to this archive)"
    echo "  https://github.com/Starry-Sky-Federation/ssf-play-lgpl-sources"
    echo "Problems and feedback: https://github.com/Starry-Sky-Federation/ssf-play"
    echo
    echo "DXMT takes its version string from git. The script therefore builds from a clone of the repository"
    echo "at the commit above and not from this archive; the files are the same."
    echo
    echo "To build from this archive when the repository cannot be cloned, make the tree a git repository"
    echo "whose only commit carries the version as an annotated tag, and skip the fetch stage:"
    echo "  mkdir -p \"\$SSFPLAY_WORK/build\" && cp -R dxmt \"\$SSFPLAY_WORK/build/dxmt-src\""
    echo "  cd \"\$SSFPLAY_WORK/build/dxmt-src\""
    echo "  git init -q && git add -A"
    echo "  git -c user.name=local -c user.email=local@localhost commit -q -m \"DXMT $desc\""
    echo "  git -c user.name=local -c user.email=local@localhost tag -a -m \"DXMT $desc\" $desc"
    echo "then, in the directory of the build scripts, with DXMT_REF=$desc in the environment:"
    echo "  bash scripts/build-dxmt.sh llvm, then build, install and verify"
    echo "The version string in the files is then the same; the commit recorded in VERSION is the local one."
  } > "$stage/$name/SOURCE.txt"
  if [ -e "$out" ]; then /bin/mv "$out" "$out.old-$STAMP"; fi
  # No Finder metadata, and no name of the build machine's user in the archive.
  ( cd "$stage" && COPYFILE_DISABLE=1 /usr/bin/tar -czf "$out.part" --no-mac-metadata --no-xattrs \
      --uid 0 --gid 0 --uname root --gname wheel "$name" )
  t="$(/usr/bin/tar -tzf "$out.part" | /usr/bin/grep -c -v '/$' || true)"
  [ "$t" -eq $((n + 1)) ] || fail "the archive holds $t files, expected $((n + 1)); see $out.part"
  t="$(/usr/bin/tar -tzf "$out.part" | LC_ALL=C /usr/bin/grep -c "^$name/dxmt/$SOURCE_OMIT" || true)"
  [ "$t" -eq 0 ] || fail "the archive contains $t entries below $SOURCE_OMIT; see $out.part"
  /bin/mv "$out.part" "$out"
  echo "  $n files of DXMT $desc and SOURCE.txt"
  if [ -s "$omitted" ]; then
    echo "  left out ($(/usr/bin/grep -c . "$omitted") files without a licence statement, not used by the build):"
    /usr/bin/sed 's/^/    /' "$omitted"
  fi
  echo "  $(/usr/bin/du -h "$out" | /usr/bin/cut -f1)  sha256 $(/usr/bin/shasum -a 256 "$out" | /usr/bin/cut -d' ' -f1)"
  echo "[OK] $out"
  echo "     The packaging takes it from there and writes its sha256 to SHA256SUMS.txt."
  echo "     Publish it in the same place as the disk images."
}

case "$STAGE" in
  fetch) need_work_outside_home; do_fetch ;;
  llvm) need_work_outside_home; do_llvm ;;
  build) need_work_outside_home; do_build ;;
  install) do_install ;;
  verify) do_verify ;;
  source) do_source ;;
  all)
    # Everything that can be missing is checked before the long LLVM build, not after it.
    need_work_outside_home
    need_toolchain
    need_wine
    need_rosetta
    need_metal
    do_fetch; do_llvm; do_build; do_install; do_verify
    ;;
esac
