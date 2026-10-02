#!/bin/bash
# Build Wine from the CrossOver open-source tarball: x86_64 Unix side, x86_64 and i386 PE side.
#
# The system compiler runs natively and targets x86_64; configure's test programs and the
# finished Wine run under Rosetta 2. The build dependencies and the llvm-mingw PE cross-compiler
# come from the user-level MacPorts prefix made by scripts/setup-macports.sh. Everything is
# written below the work directory; nothing is installed system-wide and nothing needs sudo.
#
# Usage: bash scripts/build-wine.sh <stage>
#   fetch      download and unpack crossover-sources-<CX_VER>.tar.gz
#   patch      apply patches/wine/series to the Wine sources (applied patches are skipped)
#   configure  configure an out-of-tree build in <work>/build/wine-build
#   build      make (a few minutes on a recent Mac, much longer on older ones)
#   install    make install through DESTDIR, then move the tree to <work>/build/wine and add the licence
#              texts: Wine's own (share/licenses/wine) and those of the libraries in Wine's libs/ directory
#              that are compiled into it (share/licenses/wine-libs/<library>)
#   verify     run the built wine and check that no build path ended up in the binaries
#   all        the six stages above, in order
#
# Environment:
#   SSFPLAY_WORK    work directory (default: <repo>/work)
#   SSFPLAY_PREFIX  prefix compiled into Wine (default: /opt/ssfplay)
#   SSFPLAY_JOBS    parallel make jobs (default: number of CPUs)
#   CX_VER          CrossOver source release (default: 26.3.0)
set -euo pipefail

usage() {
  echo "Usage: bash $0 fetch|patch|configure|build|install|verify|all"
}

STAGE="${1:-}"
case "$STAGE" in
  fetch|patch|configure|build|install|verify|all) ;;
  *) usage; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SSFPLAY_WORK:-$ROOT/work}"
case "$WORK" in
  /*) ;;
  *) echo "[FAIL] SSFPLAY_WORK must be an absolute path"; exit 1 ;;
esac
# Compiler and flags are passed to make as plain words, and autoconf rejects such paths anyway.
no_whitespace() {
  case "$1" in
    *[[:space:]]*) echo "[FAIL] the repository and work paths must not contain whitespace"; exit 1 ;;
  esac
}
no_whitespace "$ROOT$WORK"
/bin/mkdir -p "$WORK"

BUILD="$WORK/build"
SRC="$BUILD/src"
OBJ="$BUILD/wine-build"
DEST="$BUILD/wine"
MP="$WORK/macports"
TC="$MP/libexec/llvm-mingw"   # PE cross-compiler, installed by the llvm-mingw port
CX_VER="${CX_VER:-26.3.0}"
CX_PINNED_VER="26.3.0"
CX_PINNED_SHA256="ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
WINE_SRC="$SRC/cx-$CX_VER/sources/wine"
# In the Wine sources; installed to share/licenses/wine. LICENSE.OLD is the notice of the code from before
# Wine became LGPL.
WINE_LICENCE_FILES="LICENSE LICENSE.OLD COPYING.LIB AUTHORS"
# The third-party libraries in the libs/ directory of the Wine sources. Wine compiles them into its Windows
# modules, so their licence texts have to travel with the binaries as Wine's own do. Each keeps its licence
# files at the top of its directory. The other directories in libs/ are Wine's own code.
WINE_BUNDLED_LIBS="capstone compiler-rt faudio fluidsynth gsm jpeg jxr lcms2 ldap mpg123 musl png tiff tomcrypt vkd3d xml2 xslt zlib"
JOBS="${SSFPLAY_JOBS:-$(/usr/sbin/sysctl -n hw.ncpu)}"
STAMP="$(/bin/date +%Y%m%d-%H%M%S)"

# The prefix compiled into the binaries is a neutral path, not a directory of the build machine.
# Wine finds its files relative to its own executable at run time, so the prefix is only a
# compile-time default; the files reach the disk through "make install DESTDIR=...".
PREFIX="${SSFPLAY_PREFIX:-/opt/ssfplay}"
PREFIX="${PREFIX%/}"
case "$PREFIX" in
  /?*) ;;
  *) echo "[FAIL] SSFPLAY_PREFIX must be an absolute path below /"; exit 1 ;;
esac

# Keep build-machine paths out of the binaries: __FILE__ and debug information are rewritten.
# When the work directory lies inside the repository both maps match; either result is neutral.
# If a symbolic link is involved, the resolved spelling (what getcwd() reports) is mapped as well.
# BUILD_PATHS is what the verify stage looks for afterwards.
PATHMAP="-ffile-prefix-map=$WORK=/ssfplay/work -ffile-prefix-map=$ROOT=/ssfplay"
BUILD_PATHS=("$ROOT" "$WORK")
ROOT_REAL="$(cd "$ROOT" && pwd -P)"
WORK_REAL="$(cd "$WORK" && pwd -P)"
no_whitespace "$ROOT_REAL$WORK_REAL"
if [ "$WORK_REAL" != "$WORK" ]; then
  PATHMAP="$PATHMAP -ffile-prefix-map=$WORK_REAL=/ssfplay/work"; BUILD_PATHS+=("$WORK_REAL")
fi
if [ "$ROOT_REAL" != "$ROOT" ]; then
  PATHMAP="$PATHMAP -ffile-prefix-map=$ROOT_REAL=/ssfplay"; BUILD_PATHS+=("$ROOT_REAL")
fi

# Run a command in the cross-build environment.
# - env -i keeps the caller's shell environment (other package managers, other compilers) out.
# - The macOS toolchain binaries are arm64-only, so the compiler runs natively and x86_64 output
#   is requested explicitly with -arch x86_64.
# - PATH: llvm-mingw first (PE side), then the MacPorts tools (bison, flex, pkg-config), then the system.
xbuild() {
  /usr/bin/env -i \
    HOME="$HOME" USER="${USER:-$(/usr/bin/id -un)}" LOGNAME="${USER:-$(/usr/bin/id -un)}" \
    TERM="${TERM:-xterm-256color}" \
    PATH="$TC/bin:$MP/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    CC="/usr/bin/clang -arch x86_64" \
    CXX="/usr/bin/clang++ -arch x86_64" \
    CFLAGS="-O2 -I$MP/include $PATHMAP" \
    CXXFLAGS="-O2 -I$MP/include $PATHMAP" \
    LDFLAGS="-L$MP/lib" \
    PKG_CONFIG="$MP/bin/pkg-config" \
    PKG_CONFIG_PATH="$MP/lib/pkgconfig:$MP/share/pkgconfig" \
    CROSSCFLAGS="-O2 $PATHMAP" \
    "$@"
}

need_sources() {
  [ -x "$WINE_SRC/configure" ] || { echo "[FAIL] no Wine sources at $WINE_SRC; run the fetch stage first"; exit 1; }
}

need_toolchain() {
  [ -x "$TC/bin/clang" ] || {
    echo "[FAIL] llvm-mingw not found at $TC; run scripts/setup-macports.sh first"; exit 1; }
  [ -x "$MP/bin/pkg-config" ] || {
    echo "[FAIL] pkg-config not found in $MP/bin; run scripts/setup-macports.sh first"; exit 1; }
  /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || {
    echo "[FAIL] Rosetta 2 is required: softwareupdate --install-rosetta --agree-to-license"; exit 1; }
}

do_fetch() {
  echo "== fetch: crossover-sources-$CX_VER =="
  /bin/mkdir -p "$SRC"
  local tgz="$BUILD/crossover-sources-$CX_VER.tar.gz"
  if [ ! -s "$tgz" ]; then
    # Download under a temporary name so that an interrupted transfer is never taken for the tarball.
    /usr/bin/curl -fL --retry 3 -o "$tgz.part" \
      "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VER.tar.gz"
    /bin/mv "$tgz.part" "$tgz"
  fi
  /usr/bin/du -sh "$tgz"
  if [ "$CX_VER" = "$CX_PINNED_VER" ]; then
    local sum
    sum="$(/usr/bin/shasum -a 256 "$tgz" | /usr/bin/cut -d' ' -f1)"
    [ "$sum" = "$CX_PINNED_SHA256" ] || {
      echo "[FAIL] sha256 mismatch for $tgz"
      echo "       expected $CX_PINNED_SHA256"
      echo "       got      $sum"
      echo "       Move the file away and run fetch again."
      exit 1
    }
    echo "  sha256 matches the pinned value"
  else
    echo "  [NOTE] no checksum is pinned for CX_VER=$CX_VER; the tarball is not verified"
  fi
  if [ ! -d "$SRC/cx-$CX_VER" ]; then
    # Unpack next to the final location and rename, so that a half-unpacked tree is never used.
    local tmp="$SRC/cx-$CX_VER.unpacking"
    if [ -e "$tmp" ]; then /bin/mv "$tmp" "$tmp.old-$STAMP"; fi
    /bin/mkdir -p "$tmp"
    /usr/bin/tar xf "$tgz" -C "$tmp"
    /bin/mv "$tmp" "$SRC/cx-$CX_VER"
  fi
  [ -x "$WINE_SRC/configure" ] || {
    echo "[FAIL] no configure script at $WINE_SRC; the tarball layout differs from what this script expects:"
    /bin/ls "$SRC/cx-$CX_VER" || true
    exit 1
  }
  echo "[OK] Wine sources: $WINE_SRC"
  /usr/bin/head -1 "$WINE_SRC/VERSION" 2>/dev/null || true
}

do_patch() {
  echo "== patch: apply patches/wine/series =="
  need_sources
  local series="$ROOT/patches/wine/series"
  [ -f "$series" ] || { echo "[FAIL] missing $series"; exit 1; }
  local applied=0 skipped=0 pf full
  while IFS= read -r pf || [ -n "$pf" ]; do
    [ -z "$pf" ] && continue
    case "$pf" in \#*) continue ;; esac
    full="$ROOT/patches/wine/$pf"
    [ -f "$full" ] || { echo "[FAIL] missing patch file $full"; exit 1; }
    # A reverse dry run that succeeds means the patch is already in the tree.
    if ( cd "$WINE_SRC" && /usr/bin/patch -p1 -R --dry-run -s -f < "$full" >/dev/null 2>&1 ); then
      echo "  [applied earlier] $pf"; skipped=$((skipped+1)); continue
    fi
    if ( cd "$WINE_SRC" && /usr/bin/patch -p1 --dry-run -s -f < "$full" >/dev/null 2>&1 ); then
      ( cd "$WINE_SRC" && /usr/bin/patch -p1 -s -f --no-backup-if-mismatch < "$full" )
      echo "  [applied] $pf"; applied=$((applied+1))
    else
      echo "[FAIL] $pf applies neither forwards nor backwards; the source tree was probably edited by hand:"
      ( cd "$WINE_SRC" && /usr/bin/patch -p1 --dry-run -f < "$full" ) || true
      exit 1
    fi
  done < "$series"
  echo "[OK] patch: $applied applied, $skipped skipped (origins: patches/README.md)"
  # 0001 changes the build tools (makedep, winegcc), which are only rebuilt from a fresh configure.
  echo "     If the series changed after an earlier build, move $OBJ aside and run configure again."
}

do_configure() {
  echo "== configure =="
  need_sources
  need_toolchain
  /bin/mkdir -p "$OBJ"
  # The flag set follows the wine-stable port of Gcenx/macports-wine. Vulkan is off because the
  # runtime ships no MoltenVK (patch 0002 makes that configuration compile); the other --without
  # flags disable Linux-only or unused back ends, so that the result does not depend on what
  # happens to be installed.
  ( cd "$OBJ" && xbuild "$WINE_SRC/configure" \
      --prefix="$PREFIX" \
      --build=x86_64-apple-darwin27 \
      --enable-archs=i386,x86_64 \
      --disable-tests --disable-winemenubuilder \
      --with-mingw="$TC/bin/clang" \
      --without-vulkan \
      --without-alsa --without-capi --without-dbus --without-ffmpeg \
      --without-fontconfig --without-gphoto --without-gssapi --without-gstreamer \
      --without-krb5 --without-netapi --without-opengl --without-oss \
      --without-pulse --without-sane --without-udev --without-usb \
      --without-v4l2 --without-wayland --without-x )
  echo "[OK] configure finished. Read the WARNING lines above before building:"
  echo "     a library that was not found silently removes a feature."
}

do_build() {
  echo "== build: make -j$JOBS =="
  need_toolchain
  [ -f "$OBJ/Makefile" ] || { echo "[FAIL] no Makefile in $OBJ; run the configure stage first"; exit 1; }
  ( cd "$OBJ" && xbuild make -j"$JOBS" )
  echo "[OK] build finished"
}

# Is this file name that of a licence text, a copyright notice or a list of authors?
is_licence_name() {
  case "$(printf '%s' "$1" | LC_ALL=C /usr/bin/tr '[:lower:]' '[:upper:]')" in
    LICENSE*|LICENCE*|COPYING*|COPYRIGHT*|NOTICE*|AUTHORS*|CREDITS*|PATENTS*) return 0 ;;
    *) return 1 ;;
  esac
}

# Copy the licence files of every library in libs/ that the build compiled to <tree>/share/licenses/wine-libs.
# Not only the libraries named in WINE_BUNDLED_LIBS: a library that a later Wine adds is picked up as well.
install_lib_licences() {  # install_lib_licences <installed Wine tree>
  local dest="$1/share/licenses/wine-libs" d lib f n libs=0 files=0
  for d in "$WINE_SRC"/libs/*/; do
    lib="$(/usr/bin/basename "$d")"
    [ -d "$OBJ/libs/$lib" ] || continue   # not compiled in this build
    n=0
    for f in "$d"*; do
      [ -f "$f" ] || continue
      is_licence_name "$(/usr/bin/basename "$f")" || continue
      /bin/mkdir -p "$dest/$lib"
      /bin/cp "$f" "$dest/$lib/"
      n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then libs=$((libs+1)); files=$((files+n)); fi
  done
  for lib in $WINE_BUNDLED_LIBS; do
    [ -d "$OBJ/libs/$lib" ] || { echo "  [note] libs/$lib was not compiled in this build; no licence text installed for it"; continue; }
    [ -n "$(/bin/ls -A "$dest/$lib" 2>/dev/null)" ] || {
      echo "[FAIL] the Wine sources have no licence file at the top of libs/$lib;"
      echo "       look at that directory and correct install_lib_licences in $0"
      exit 1
    }
  done
  echo "  licence texts of $libs bundled libraries ($files files) -> share/licenses/wine-libs"
}

do_install() {
  echo "== install: $DEST (through DESTDIR; compiled-in prefix $PREFIX) =="
  [ -f "$OBJ/Makefile" ] || { echo "[FAIL] no Makefile in $OBJ; run configure and build first"; exit 1; }
  need_sources
  local destdir="$BUILD/wine-destdir" f
  for f in $WINE_LICENCE_FILES; do
    [ -f "$WINE_SRC/$f" ] || { echo "[FAIL] the Wine sources have no $f; its licence texts cannot be installed"; exit 1; }
  done
  if [ -e "$destdir" ]; then /bin/mv "$destdir" "$destdir.old-$STAMP"; fi
  ( cd "$OBJ" && xbuild make install DESTDIR="$destdir" >/dev/null )
  [ -x "$destdir$PREFIX/bin/wine" ] || { echo "[FAIL] make install produced no wine in $destdir$PREFIX"; exit 1; }
  if [ -e "$DEST" ]; then
    /bin/mv "$DEST" "$DEST.bak-$STAMP"
    echo "  previous tree renamed to $DEST.bak-$STAMP (to roll back, rename it back)"
  fi
  /bin/mv "$destdir$PREFIX" "$DEST"
  # "make install" installs no licence file. Wine is LGPL: its notice, the licence text and the list of
  # authors the notice refers to have to travel with the binaries, and so do the licence texts of the
  # libraries compiled into it. The packaging ships share/licenses as it is.
  /bin/mkdir -p "$DEST/share/licenses/wine"
  for f in $WINE_LICENCE_FILES; do /bin/cp "$WINE_SRC/$f" "$DEST/share/licenses/wine/$f"; done
  install_lib_licences "$DEST"
  # Only the empty parent directories of the prefix are left behind.
  /usr/bin/find "$destdir" -depth -type d -empty -exec /bin/rmdir {} \; 2>/dev/null || true
  echo "[OK] installed:"
  /bin/ls "$DEST/bin"
}

# List the installed files that contain a path of the build machine.
# One kind of occurrence is expected and tolerated: a Mach-O load command that names a MacPorts
# library by its absolute path (wineserver and a few Unix-side modules link such libraries
# directly). The packaging step copies those libraries into the runtime and rewrites the
# references, and checks the result itself. Everything else is a leak.
# include/ is not scanned: generated headers name their source files, and they are not shipped.
scan_build_paths() {
  local patterns=() dirs=() p d f total expected leak leaks=0 linked=0
  for p in "${BUILD_PATHS[@]}"; do patterns+=(-e "$p"); done
  for d in "$DEST/bin" "$DEST/lib" "$DEST/share"; do
    if [ -d "$d" ]; then dirs+=("$d"); fi
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    leak=0
    for p in "${BUILD_PATHS[@]}"; do
      # Occurrences of the path in the file, against load commands for MacPorts libraries that contain it.
      total=$(( $(LC_ALL=C /usr/bin/grep -aoF -e "$p" "$f" | /usr/bin/wc -l || true) ))
      expected=$(( $(/usr/bin/otool -L "$f" 2>/dev/null | /usr/bin/sed 1d \
        | LC_ALL=C /usr/bin/grep -F -e "$MP/lib/" -e "$WORK_REAL/macports/lib/" \
        | LC_ALL=C /usr/bin/grep -F -e "$p" | /usr/bin/wc -l || true) ))
      if [ "$total" -gt "$expected" ]; then leak=1; fi
    done
    if [ "$leak" = 1 ]; then
      echo "  [LEAK] ${f#"$DEST"/}"
      leaks=$((leaks+1))
    else
      echo "  [note] ${f#"$DEST"/} links a MacPorts library by absolute path"
      linked=$((linked+1))
    fi
  done < <(LC_ALL=C /usr/bin/grep -rlF "${patterns[@]}" "${dirs[@]}" 2>/dev/null || true)
  if [ "$leaks" -gt 0 ]; then
    echo "[FAIL] $leaks installed file(s) contain a path of this machine."
    echo "       Something was compiled without the prefix maps. Move $OBJ aside,"
    echo "       then run configure, build and install again."
    return 1
  fi
  echo "  no build path in bin/, lib/ or share/"
  if [ "$linked" -gt 0 ]; then
    echo "  ($linked file(s) reference MacPorts libraries; the packaging embeds them and rewrites the references)"
  fi
}

do_verify() {
  echo "== verify =="
  [ -x "$DEST/bin/wine" ] || { echo "[FAIL] no wine in $DEST/bin; run the install stage first"; exit 1; }
  [ -d "$DEST/lib/wine/x86_64-unix" ] || { echo "[FAIL] $DEST/lib/wine/x86_64-unix is missing"; exit 1; }
  local f
  for f in $WINE_LICENCE_FILES; do
    [ -s "$DEST/share/licenses/wine/$f" ] || {
      echo "[FAIL] $DEST/share/licenses/wine/$f is missing; run the install stage again"; exit 1; }
  done
  for f in $WINE_BUNDLED_LIBS; do
    # A library that this build did not compile has no directory here and needs none.
    if [ -d "$OBJ" ] && [ ! -d "$OBJ/libs/$f" ]; then continue; fi
    [ -n "$(/bin/ls -A "$DEST/share/licenses/wine-libs/$f" 2>/dev/null)" ] || {
      echo "[FAIL] $DEST/share/licenses/wine-libs/$f is missing or empty; run the install stage again"; exit 1; }
  done
  /usr/bin/arch -x86_64 "$DEST/bin/wine" --version
  scan_build_paths || exit 1
  echo "[OK] verify passed"
}

case "$STAGE" in
  fetch) do_fetch ;;
  patch) do_patch ;;
  configure) do_configure ;;
  build) do_build ;;
  install) do_install ;;
  verify) do_verify ;;
  all) do_fetch; do_patch; do_configure; do_build; do_install; do_verify ;;
esac
