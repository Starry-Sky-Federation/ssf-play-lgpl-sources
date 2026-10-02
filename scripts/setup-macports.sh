#!/bin/bash
# setup-macports.sh - user-level x86_64 MacPorts with the libraries and compilers Wine is built with.
#
# The Wine in this project is an x86_64 build that runs under Rosetta 2, so its dependencies have
# to be x86_64 as well. On macOS 27 the Apple toolchain binaries are arm64-only: a compiler started
# from an x86_64 process still targets arm64, which breaks the usual "x86_64 Homebrew in /usr/local"
# approach. MacPorts' build_arch passes -arch x86_64 to every compile instead, while the compiler
# itself runs natively.
#
# Everything is installed without root, inside the work directory:
#   macports/                  the MacPorts prefix (never added to PATH; always called by absolute path)
#   build/macports-base-src/   MacPorts base source
#   build/macports-ports/      official ports tree, with patches/macports applied
#   build/macports-wine/       Gcenx's overlay tree (provides the llvm-mingw port)
#   build/macports-logs/       logs of the maintenance stages
# Nothing outside the work directory is touched.
#
# Requirements: Apple Silicon, Rosetta 2 and a full Xcode (the Command Line Tools alone are not
# enough, see do_conf). Choose a work directory outside your home directory before the first run:
# scripts/build-dxmt.sh needs that (see warn_work_below_home), and this MacPorts cannot be moved.
#
# Usage: scripts/setup-macports.sh [stage]
#   First-time setup: bootstrap, then deps, then verify.
#     bootstrap     base + conf + ports + sync (default)
#     base          build and install MacPorts itself (about 10 minutes)
#     conf          write the x86_64 configuration and apply the developer_dir fix
#     ports         clone the two ports trees and apply patches/macports
#     sync          build the port indexes (5-10 minutes the first time)
#     deps          install Wine's build dependencies (compiled from source; takes hours)
#     verify        show what is installed and check that the key libraries are x86_64
#   Maintenance:
#     update        move both ports trees to upstream HEAD, re-apply patches/macports, re-index
#     upgrade       upgrade the outdated ports (compiled from source)
#     upgrade-base  upgrade MacPorts itself to MP_VER (edit it below first), then re-run conf
#
# Environment:
#   SSFPLAY_WORK    work directory (default: <repo>/work)
#   SSFPLAY_JOBS    parallel make jobs when building MacPorts itself (default: number of CPUs)
#   DEVELOPER_DIR   Xcode developer directory to record at the conf stage (default: auto-detected)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SSFPLAY_WORK:-$ROOT/work}"
MP="$WORK/macports"
MPSRC="$WORK/build/macports-base-src"
PORTS_MAIN="$WORK/build/macports-ports"
PORTS_WINE="$WORK/build/macports-wine"
LOGS="$WORK/build/macports-logs"
MP_VER=2.12.6
MP_TGZ="$WORK/build/MacPorts-$MP_VER.tar.bz2"
JOBS="${SSFPLAY_JOBS:-$(/usr/sbin/sysctl -n hw.ncpu)}"
STAGE="${1:-bootstrap}"

# Port names follow Gcenx's wine-stable Portfile. llvm-mingw (the PE cross compiler) comes from
# the overlay tree, so that it is tracked by MacPorts like every other dependency.
DEPS=(bison flex gettext pkgconfig llvm-mingw freetype gnutls-devel libinotify libpcap libsdl2)

case "$WORK" in
  *[[:space:]]*) echo "[FAIL] the work directory must not contain whitespace (MacPorts cannot live in such a path): $WORK" >&2; exit 1 ;;
esac

# DXMT, which scripts/build-dxmt.sh builds in the same work directory, compiles its shaders with Xcode's Metal
# compiler, and that compiler writes the absolute path of every shader source into the result. Below the home
# directory the path contains the user name, and build-dxmt.sh refuses to build there. This MacPorts cannot
# be moved once it is installed, so the warning comes here, before the hours of compiling.
warn_work_below_home() {
  local h="${HOME:-}" hr w wr
  h="${h%/}"
  [ -n "$h" ] || return 0
  hr="$( (cd "$h" 2>/dev/null && pwd -P) || printf '%s' "$h")"
  w="${WORK%/}"
  wr="$( (cd "$w" 2>/dev/null && pwd -P) || printf '%s' "$w")"
  case "$w/" in "$h"/*|"$hr"/*) ;; *) case "$wr/" in "$h"/*|"$hr"/*) ;; *) return 0 ;; esac ;; esac
  echo "[warning] the work directory is below your home directory: $WORK"
  echo "          scripts/build-dxmt.sh will refuse to build there: Xcode's Metal compiler writes the absolute"
  echo "          path of DXMT's shader sources into winemetal.so, which would then contain your user name."
  echo "          The MacPorts installed by this script is configured for its path and cannot be moved later."
  echo "          For anything you intend to pass on, stop now and start again outside the home directory:"
  echo "            export SSFPLAY_WORK=/Users/Shared/ssf-play-build"
  echo "          For a build that stays on this Mac you can go on, and later run scripts/build-dxmt.sh"
  echo "          with SSFPLAY_ALLOW_HOME_PATHS=1."
}

need_port() {
  [ -x "$MP/bin/port" ] || { echo "[FAIL] MacPorts is not installed in $MP; run: bash $0 base" >&2; exit 1; }
}

# Developer directory used for port builds: the one recorded in macports.conf, else $DEVELOPER_DIR,
# else the first installed Xcode. It has to ship an x86_64 slice of libxcrun (see do_conf).
developer_dir() {
  local mc="$MP/etc/macports/macports.conf" d=""
  if [ -f "$mc" ]; then
    d="$(/usr/bin/sed -n 's/^developer_dir[[:space:]][[:space:]]*//p' "$mc" | /usr/bin/tail -1)"
  fi
  if [ -n "$d" ]; then printf '%s\n' "$d"; return 0; fi
  for d in "${DEVELOPER_DIR:-}" /Applications/Xcode.app/Contents/Developer /Applications/Xcode-beta.app/Contents/Developer; do
    [ -n "$d" ] || continue
    if /usr/bin/lipo -archs "$d/usr/lib/libxcrun.dylib" 2>/dev/null | /usr/bin/grep -qw x86_64; then
      printf '%s\n' "$d"; return 0
    fi
  done
  echo "[FAIL] no Xcode with an x86_64 libxcrun found; install Xcode, or set DEVELOPER_DIR to its Contents/Developer" >&2
  return 1
}

fetch_base() {
  mkdir -p "$WORK/build"
  [ -s "$MP_TGZ" ] || /usr/bin/curl -fL --retry 3 -o "$MP_TGZ" \
    "https://github.com/macports/macports-base/releases/download/v$MP_VER/MacPorts-$MP_VER.tar.bz2"
}

# Without root the applications and frameworks directories default to the home directory;
# keep them inside the prefix so the install stays self-contained.
configure_base() {
  ./configure --prefix="$MP" --with-no-root-privileges \
    --with-applications-dir="$MP/Applications" \
    --with-frameworks-dir="$MP/Library/Frameworks"
}

do_base() {
  echo "== base: build MacPorts $MP_VER from source into $MP (no root) =="
  if [ -x "$MP/bin/port" ]; then echo "[SKIP] $MP/bin/port already exists"; return; fi
  fetch_base
  mkdir -p "$MPSRC"
  /usr/bin/tar xjf "$MP_TGZ" -C "$MPSRC" --strip-components 1
  ( cd "$MPSRC" && configure_base && make -j"$JOBS" && make install )
  "$MP/bin/port" version
  echo "[OK] MacPorts base installed"
}

do_conf() {
  echo "== conf: build_arch x86_64, developer directory, local port sources =="
  need_port
  local mc="$MP/etc/macports/macports.conf"
  local sc="$MP/etc/macports/sources.conf"
  local pc="$MP/libexec/macports/lib/port1.0/portconfigure.tcl"
  local dev
  dev="$(developer_dir)"

  [ -e "$mc.orig" ] || cp "$mc" "$mc.orig"
  /usr/bin/grep -q '^build_arch x86_64' "$mc" || \
    printf '\n# ssfplay: build every port as x86_64 only (the result runs under Rosetta 2)\nbuild_arch x86_64\nuniversal_archs\n' >> "$mc"

  # The Command Line Tools' libxcrun is arm64-only, so an x86_64 build tool (a bootstrapped cmake,
  # for example) that calls a /usr/bin shim fails to load it. Xcode's libxcrun is universal.
  # developer_dir only covers MacPorts itself; DEVELOPER_DIR must also be let through to the build
  # environment (extra_env here, exported in do_deps and do_upgrade) so that the shims run by the
  # build tools resolve to Xcode as well.
  /usr/bin/grep -q '^developer_dir' "$mc" || printf 'developer_dir %s\n' "$dev" >> "$mc"
  /usr/bin/grep -q '^extra_env' "$mc" || printf 'extra_env DEVELOPER_DIR\n' >> "$mc"

  # For ports that do not require Xcode, MacPorts still forces the Command Line Tools path and
  # ignores both settings above. Make configure_get_developer_dir return developer_dir in that
  # branch too. This edits an installed MacPorts file, so it is lost whenever base is upgraded:
  # upgrade-base re-runs this stage.
  if ! /usr/bin/grep -qF 'ssfplay-patch' "$pc"; then
    /usr/bin/sed -i.orig \
      's|        return ${cltpath}|        # ssfplay-patch: the Command Line Tools libxcrun is arm64-only\n        return ${developer_dir}|' "$pc"
    /usr/bin/grep -qF 'ssfplay-patch' "$pc" || {
      echo "[FAIL] could not apply the developer_dir fix: configure_get_developer_dir in $pc has changed" >&2
      exit 1
    }
  fi

  [ -e "$sc.orig" ] || cp "$sc" "$sc.orig"
  cat > "$sc" <<EOF
# ssfplay: local trees only; the overlay takes precedence over the official tree
file://$PORTS_WINE
file://$PORTS_MAIN [default]
EOF
  echo "[OK] configured ($mc, $sc), developer directory: $dev"
}

# patches/macports holds fixes to the official tree that upstream does not carry. Cloning or
# updating the tree drops them, so they are applied again after either.
apply_port_patches() {
  local pf name
  for pf in "$ROOT"/patches/macports/*.patch; do
    [ -f "$pf" ] || continue
    name="$(basename "$pf")"
    if /usr/bin/git -C "$PORTS_MAIN" apply --check "$pf" >/dev/null 2>&1; then
      /usr/bin/git -C "$PORTS_MAIN" apply "$pf"
      echo "[OK] applied $name"
    elif /usr/bin/git -C "$PORTS_MAIN" apply --reverse --check "$pf" >/dev/null 2>&1; then
      echo "[SKIP] $name is already applied"
    else
      echo "[WARN] $name does not apply (fixed upstream, or a conflict); review: git -C $PORTS_MAIN diff"
    fi
  done
}

do_ports() {
  echo "== ports: clone the official tree (shallow) and Gcenx's overlay =="
  mkdir -p "$WORK/build"
  [ -d "$PORTS_MAIN/.git" ] || /usr/bin/git clone --depth 1 https://github.com/macports/macports-ports "$PORTS_MAIN"
  [ -d "$PORTS_WINE/.git" ] || /usr/bin/git clone --depth 1 https://github.com/Gcenx/macports-wine "$PORTS_WINE"
  apply_port_patches
  echo "[OK] ports trees ready"
}

do_sync() {
  echo "== sync: build the port indexes (5-10 minutes the first time) =="
  need_port
  ( cd "$PORTS_MAIN" && "$MP/bin/portindex" )
  ( cd "$PORTS_WINE" && "$MP/bin/portindex" )
  echo "[OK] indexes built"
}

do_deps() {
  echo "== deps: install Wine's build dependencies (all from source, takes hours; -N = non-interactive) =="
  need_port
  local dev
  dev="$(developer_dir)"
  DEVELOPER_DIR="$dev" "$MP/bin/port" -N install "${DEPS[@]}"
  echo "[OK] dependencies installed"
}

do_update() {
  echo "== update: ports trees to upstream HEAD (shallow fetch), re-apply local patches, re-index =="
  need_port
  mkdir -p "$LOGS"
  local repo br
  for repo in "$PORTS_MAIN" "$PORTS_WINE"; do
    echo "before: $repo @ $(/usr/bin/git -C "$repo" rev-parse --short HEAD)" | tee -a "$LOGS/ports-tree-heads.log"
    br="$(/usr/bin/git -C "$repo" remote show origin 2>/dev/null | /usr/bin/sed -n 's/.*HEAD branch: //p')"
    [ -n "$br" ] || br=master
    # Local changes (the applied patches) are kept as a stash rather than discarded.
    /usr/bin/git -C "$repo" stash push -q -m "ssfplay local changes before update $(date +%F)" >/dev/null 2>&1 || true
    /usr/bin/git -C "$repo" fetch -q --depth 1 origin "$br"
    /usr/bin/git -C "$repo" reset -q --hard FETCH_HEAD
    echo "after:  $repo @ $(/usr/bin/git -C "$repo" log -1 --format='%h %ci')" | tee -a "$LOGS/ports-tree-heads.log"
  done
  apply_port_patches
  do_sync
  echo "== outdated ports =="
  "$MP/bin/port" outdated 2>&1 | /usr/bin/grep -v 'two weeks old' || true
}

do_upgrade() {
  need_port
  mkdir -p "$LOGS"
  local dev stamp log
  dev="$(developer_dir)"
  stamp="$(date +%Y%m%d)"
  log="$LOGS/port-upgrade-$stamp.log"
  echo "== upgrade: port -N upgrade outdated (all from source; full log: $log) =="
  "$MP/bin/port" installed 2>/dev/null > "$LOGS/ports-installed-before-upgrade-$stamp.txt"
  DEVELOPER_DIR="$dev" "$MP/bin/port" -N upgrade outdated 2>&1 | tee "$log" | tail -20
  "$MP/bin/port" outdated 2>&1 | /usr/bin/grep -v 'two weeks old' || true
  echo "[NOTE] Wine needs no rebuild as long as the library file names (sonames) are unchanged."
  echo "       A new llvm-mingw only affects the PE side of the next Wine build (scripts/build-wine.sh),"
  echo "       which must then start from a clean object directory."
  echo "       The previous version of a port stays installed: port installed <name>, port activate <name> @<version>."
}

do_upgrade_base() {
  echo "== upgrade-base: MacPorts to $MP_VER in place (built first, swapped in only if the build succeeds) =="
  need_port
  local cur stamp log
  cur="$("$MP/bin/port" version | /usr/bin/sed 's/Version: //')"
  if [ "$cur" = "$MP_VER" ]; then echo "[SKIP] already at $MP_VER"; return; fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOGS"
  fetch_base
  # The old source tree is renamed, not reused: files of two versions must not mix.
  if [ -e "$MPSRC" ]; then mv "$MPSRC" "$MPSRC.bak-$stamp"; fi
  mkdir -p "$MPSRC"
  /usr/bin/tar xjf "$MP_TGZ" -C "$MPSRC" --strip-components 1
  log="$LOGS/base-$MP_VER-build.log"
  ( cd "$MPSRC" && configure_base && make -j"$JOBS" ) > "$log" 2>&1 \
    || { echo "[FAIL] build failed, the installed MacPorts is untouched; see $log" >&2; exit 1; }

  mkdir -p "$MP/bin.bak-$stamp"
  cp -a "$MP/bin/." "$MP/bin.bak-$stamp/"
  mv "$MP/libexec/macports" "$MP/libexec/macports.bak-$stamp"
  mv "$MP/share/macports"   "$MP/share/macports.bak-$stamp"
  rollback_hint() {
    echo "  to roll back (the new directories are renamed, nothing is deleted):"
    echo "    mv $MP/libexec/macports $MP/libexec/macports.new-$stamp"
    echo "    mv $MP/libexec/macports.bak-$stamp $MP/libexec/macports"
    echo "    mv $MP/share/macports $MP/share/macports.new-$stamp"
    echo "    mv $MP/share/macports.bak-$stamp $MP/share/macports"
    echo "    cp -a $MP/bin.bak-$stamp/. $MP/bin/"
  }
  log="$LOGS/base-$MP_VER-install.log"
  ( cd "$MPSRC" && make install ) > "$log" 2>&1 \
    || { echo "[FAIL] install failed; see $log" >&2; rollback_hint >&2; exit 1; }
  "$MP/bin/port" version
  echo "-- re-running conf: the new base replaced the patched portconfigure.tcl --"
  do_conf
  echo "[OK] base upgraded; the previous version is kept as *.bak-$stamp"
  rollback_hint
}

do_verify() {
  echo "== verify =="
  need_port
  "$MP/bin/port" version
  "$MP/bin/port" installed || true
  local lib archs bad=0
  for lib in libfreetype.dylib libgnutls.dylib libSDL2.dylib; do
    if [ ! -f "$MP/lib/$lib" ]; then
      echo "[FAIL] $lib: missing"; bad=1
      continue
    fi
    archs="$(/usr/bin/lipo -archs "$MP/lib/$lib")"
    if [ "$archs" = x86_64 ]; then echo "[OK] $lib: $archs"; else echo "[FAIL] $lib: $archs (expected x86_64)"; bad=1; fi
  done
  if [ -x "$MP/libexec/llvm-mingw/bin/clang" ]; then
    echo "[OK] llvm-mingw: $MP/libexec/llvm-mingw"
  else
    echo "[FAIL] llvm-mingw: $MP/libexec/llvm-mingw/bin/clang is missing"; bad=1
  fi
  [ "$bad" = 0 ] || { echo "[FAIL] dependencies are incomplete; run: bash $0 deps" >&2; exit 1; }
}

case "$STAGE" in
  base) warn_work_below_home; do_base ;;
  conf) do_conf ;;
  ports) do_ports ;;
  sync) do_sync ;;
  bootstrap) warn_work_below_home; do_base; do_conf; do_ports; do_sync; warn_work_below_home ;;
  deps) do_deps ;;
  verify) do_verify ;;
  update) do_update ;;
  upgrade) do_upgrade ;;
  upgrade-base) do_upgrade_base ;;
  *) echo "usage: bash $0 [bootstrap|base|conf|ports|sync|deps|verify|update|upgrade|upgrade-base]" >&2; exit 1 ;;
esac
