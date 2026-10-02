# Patches

This directory holds every change the project makes to upstream source code. Each patch file starts with a header that states where the patch comes from, what it changes, and when it was changed or committed. It is published with every release, together with the scripts that apply the patches and build the result, in `ssf-play-lgpl-sources-<version>.tar.gz`.

There are no patches for DXMT, LLVM or x87sidecar: they are built from the unmodified upstream sources, DXMT and LLVM by `scripts/build-dxmt.sh`.

## `wine/`

Applied with `patch -p1`, in the order given in `wine/series`, to `sources/wine` of `crossover-sources-26.3.0.tar.gz` (Wine 11.0 as published by CodeWeavers for CrossOver 26.3.0).

| No. | File | Origin | What it changes | Licence |
|---|---|---|---|---|
| 0001 | `0001-upstream-llvm-mingw-and-syscall-abi-fixes-cx26.3.patch` | Gcenx/macports-wine, `emulators/wine-stable/files/llvm-mingw_fixes.patch`: nine commits cherry-picked from upstream Wine. Adapted by hand to the CrossOver 26.3 tree, because one hunk in `dlls/ntdll/unix/loader.c` conflicts with a CodeWeavers change and Gcenx's file does not apply as it is. | Lets the PE side of Wine 11.0 build with llvm-mingw for x86_64 and i386: the ntdll syscall dispatcher moves to `unix/syscall.c`, `winegcc` gains `--cc-cmd`, `winebuild` finds the `llvm-*` tools, `makedep` passes `CC` through, and two tests are fixed. The ARM64 parts (exception dispatcher machine frame, stack-packing ABI wrapper) compile but are not used by this x86_64 build. | LGPL-2.1-or-later |
| 0002 | `0002-win32u-vulkan-soname-runtime-fallback.patch` | Original work of this project. | `dlls/win32u/vulkan.c` refers to `SONAME_LIBVULKAN` unconditionally and does not compile when Wine is configured `--without-vulkan`. The patch defines a default name, `libMoltenVK.dylib`. If that library cannot be loaded at run time, Vulkan is simply unavailable. The runtime ships no MoltenVK, so Vulkan stays off. | LGPL-2.1-or-later |
| 0003 | `0003-sechost-cfgmgr32-tolerate-invalid-device-notify-handle.patch` | Backport written for this project. It follows the approach of upstream Wine 11.7 (commits `d8aa0ab`, `f38f3ac`) and Wine 11.8 (commit `a0236b6`). | Steam passes stale or invalid `HDEVNOTIFY` and `HCMNOTIFICATION` handles when it shuts down. Wine dereferenced them as list entries and wrote through a wild pointer, which crashed the process. The patch adds a magic-number check and a page-fault guard in `dlls/sechost/service.c` and `dlls/cfgmgr32/main.c`. | LGPL-2.1-or-later |
| 0004 | `0004-winemac-hide-gl-client-views-debug-switch.patch` | Original work of this project. | A diagnostic switch in `dlls/winemac.drv/window.c`: with `MACDRV_HIDE_GL_CLIENT_VIEWS=1` the OpenGL client view stays hidden. It exists to investigate a black Steam client window and must never be set while a game runs; the launcher unsets it. Without the variable nothing changes. | LGPL-2.1-or-later |
| 0005 | `0005-ntdll-keep-no-exec-on-under-rosetta.patch` | athei/wine, commit `539aa62`, unmodified. | Wine switched data execution prevention off for the whole process as soon as any loaded module lacked the `NX_COMPAT` flag, and then made every readable mapping executable. Under Rosetta, pages that are both writable and executable are expensive. The patch decides from the main executable only, as Windows does, and keeps DEP on under Rosetta. It affects 32-bit processes only. `WINE_DISABLE_NX_COMPAT=0` restores the Windows behaviour. | LGPL-2.1-or-later |
| 0006 | `0006-ntdll-rosetta-x87-sidecar-cooperative-attach.patch` | athei/wine, commit `e00a772`, unmodified. | Changes `dlls/ntdll/unix/loader.c` and adds `coop_proto.h`. When `ROSETTA_X87_PATH` names an x87sidecar binary, every 32-bit process is re-executed through `x87sidecar --cooperative` and hands its task and main-thread ports to the sidecar in a handshake at the top of `__wine_main`. Without the variable the patch has no effect. The sidecar itself is built from <https://github.com/athei/x87sidecar> at the tag `v1.7.0`, unmodified. | LGPL-2.1-or-later. `coop_proto.h` is a verbatim copy of the protocol header in x87sidecar, which is MIT-licensed. |

Who wrote what:

- **Original work of this project:** 0002 and 0004.
- **Gcenx:** 0001 is Gcenx's collection of upstream Wine commits, adapted here to the CrossOver tree. The `Changed-by` line in its header says what had to change.
- **athei:** 0005 and 0006. Both keep the `git format-patch` header of the original commit, with the author and the commit date.
- **Upstream Wine:** the nine commits inside 0001, and the three commits that 0003 reproduces for Wine 11.0. 0003 was written for this project; the fix itself is upstream's.

All six are derivatives of Wine and carry Wine's licence. `THIRD_PARTY_LICENSES.md`, next to this directory, lists the sources they are applied to.

### Applying the series

```bash
bash scripts/build-wine.sh fetch    # download and unpack the CrossOver sources
bash scripts/build-wine.sh patch    # apply wine/series
```

The `patch` stage can be run again at any time. A patch that is already in the tree (a reverse dry run succeeds) is skipped. A patch that applies neither forwards nor backwards stops the stage: the source tree was edited by hand, or `CX_VER` selects a release the series was not made for.

0001 changes Wine's own build tools, which are only rebuilt from a fresh `configure`. After changing the series, move the object directory (`work/build/wine-build`) aside and run the `configure` stage again.

## `macports/`

Applied with `git apply` to the official MacPorts ports tree in `work/build/macports-ports`.

| File | Origin | What it changes | Licence |
|---|---|---|---|
| `0001-nettle-libffi-explicit-x86_64-build-triplet.patch` | Original work of this project. | With `build_arch x86_64` on an Apple Silicon host, `config.guess` in nettle and libffi looks only at `uname` and picks aarch64: nettle then selects ARM assembly and libffi selects its aarch64 sources. The patch passes `--build=x86_64-apple-darwin${os.major}` explicitly in both Portfiles. | BSD-3-Clause, as the MacPorts Portfiles |

`scripts/setup-macports.sh` applies it in the `ports` stage and again in the `update` stage, because cloning or updating the ports tree drops local changes.

One more change to third-party code is not kept as a patch file: the `conf` stage of `scripts/setup-macports.sh` edits one line of the installed MacPorts (`portconfigure.tcl`) so that the configured developer directory is used instead of the Command Line Tools. The comments in that script give the reason.
