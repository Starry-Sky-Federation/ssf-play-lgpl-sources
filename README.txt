SSF Play 1.0.0: patches and build scripts of the LGPL components

The SSF Play runtime contains Wine and DXMT, both under the GNU Lesser General Public License, version 2.1
or later, and several libraries under the LGPL that are built with MacPorts. This archive holds what
SSF Play adds to their upstream sources, and the scripts that build them:

  patches/wine/               the patches to Wine; patches/wine/series gives the order
  patches/macports/           the patch to the MacPorts ports tree
  patches/README.md           origin, author and licence of every patch
  scripts/setup-macports.sh   builds the libraries Wine uses, as x86_64, in a MacPorts of its own
  scripts/build-wine.sh       fetches the Wine sources, applies the patches, builds and installs Wine
  scripts/build-dxmt.sh       builds DXMT and the LLVM libraries it links, from unchanged upstream sources
  THIRD_PARTY_LICENSES.md     every component of the runtime, its licence, and where its source is
  LICENSE                     the licence of the three scripts and of this file (MIT)

The upstream sources, in the same place as this archive:
  https://play.ssf.network/source/crossover-sources-26.3.0.tar.gz
      Wine as published by CodeWeavers for CrossOver 26.3.0, unchanged; build-wine.sh checks its sha256
  https://play.ssf.network/source/dxmt-v0.80-247-gfb45156-src.tar.gz
      DXMT with its submodules, unchanged; SOURCE.txt in it names the commits
The source archives of the MacPorts libraries are named, with sha256 and download addresses, in
share/licenses/BUNDLED-PORTS.txt of every runtime, next to the commits of the ports trees that they were
built from. The files of this archive are also at
  https://github.com/Starry-Sky-Federation/ssf-play-lgpl-sources   (tag v1.0.0)

Building
  You need an Apple Silicon Mac with Rosetta 2, a full Xcode with its Metal toolchain, and meson, ninja and
  cmake. The header of each script lists its stages and what it needs.
    export SSFPLAY_WORK=/Users/Shared/ssf-play-build    # a work directory outside the home directory
    bash scripts/setup-macports.sh bootstrap
    bash scripts/setup-macports.sh deps
    bash scripts/build-wine.sh all
    bash scripts/build-dxmt.sh all
  The results are build/wine and build/dxmt in the work directory; the libraries are in macports/lib there.

Using your own build in an installed runtime
  The runtime is the folder ~/Library/Application Support/SSF Play/wine. It is outside the app bundles, so
  changing it does not touch the signature of an app. An app replaces it only when a release with another
  runtime is installed, and then it renames the old one and does not delete it. Quit the apps and Steam
  before you change anything.
  - Wine: the files below bin/, lib/wine/ and share/wine/ of your Wine tree replace those of the runtime.
    A few files of a Wine tree load a MacPorts library by its absolute path (build-wine.sh verify lists
    them); they need the install_name_tool -change step given below. In lib/wine/x86_64-windows and
    lib/wine/i386-windows of the runtime, d3d11.dll, dxgi.dll and d3d10core.dll are DXMT's files while DXMT
    is in use: leave them out, or put DXMT's back afterwards.
  - DXMT: x86_64-unix/winemetal.so goes to lib/wine/x86_64-unix/, x86_64-windows/winemetal.dll to
    lib/wine/x86_64-windows/, and x86_64-windows/{d3d11,dxgi,d3d10core}.dll to lib/gfx/dxmt/ (the graphics
    switch copies them from there) and, while DXMT is the selected layer, also to lib/wine/x86_64-windows/.
    In the full edition, i386-windows/{d3d11,dxgi,d3d10core,winemetal}.dll go to lib/wine/i386-windows/.
  - A library built with MacPorts: it is stored in lib/wine/x86_64-unix/ under the name it is referenced
    by (for example libgnutls.30.dylib). Give your build that name, make its own name and the names of
    the libraries it loads relative, and sign it again:
      install_name_tool -id @loader_path/<name> <file>
      install_name_tool -change <absolute path of a library it loads> @loader_path/<that library> <file>
      codesign --force --sign - <file>
    Wine's executables are signed so that they may load libraries signed by anyone.

Problems and feedback: https://github.com/Starry-Sky-Federation/ssf-play
