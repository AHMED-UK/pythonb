# pythonb

Cross-compile pre-patched CPython for Termux using Android NDK r29 and API 24.
The build supports Python 3.13.15 and 3.14.7 on aarch64, arm, i686, and x86_64.

## Build

Use a Linux x86_64 host with NDK r29 and the Termux build tools. CI uses
`ghcr.io/crotm/termux-builder:latest`, which supplies these prerequisites.
The script needs Bash, GCC, make, curl, patch, pkg-config, binutils, tar, xz,
zstd, and the tools required to build CPython, mpdecimal, and libxcrypt.

```sh
TERMUX_NDK_HOME=/path/to/android-ndk-r29 \
  TERMUX_ARCH=i686 PYTHON_VERSION=3.14.7 bash build.sh
```

`TERMUX_ARCH` defaults to `aarch64`; `PYTHON_VERSION` defaults to `3.13.15`.
The NDK is resolved from `TERMUX_NDK_HOME`, then `NDK`, then
`$HOME/lib/android-ndk-r29`. The script modifies the NDK sysroot headers, so
use a dedicated, writable NDK installation.

Downloads are cached in `downloads/`. Build files use `work-<arch>/`, and
host Python builds use `build-python-<version>/`. Set `DOWNLOADS`, `WORKDIR`,
`BUILD_PYTHON_DIR`, or `OUTPUT_DIR` to absolute paths to override these locations.
Use separate work directories for concurrent builds. Output packages and SHA256
files are written to `output/`.

## Packages

Packages are named `python3.13` and `python3.14`, but install shared commands
such as `python3` under `/data/data/com.termux/files/usr`. They explicitly
conflict with one another and with Termux's official `python` package.
They are not side-by-side installations; do not force file overwrites.
Replacing official Python can affect packages that depend on it.
Pip is not bundled (`--without-ensurepip`).

OpenSSL comes from the Termux `openssl` package. Its libraries must remain
in the extracted dependency prefix; AOSP's BoringSSL is not a substitute.
The build aborts if required dependencies or extension modules are missing.

## Checks And Releases

```sh
bash -n build.sh
python3 -m unittest discover -s tests -v
```

These regression tests exercise build configuration and packaging with temporary
fixtures. A full cross-build and Android runtime tests still require the target
toolchain and environment.

Pushing a `v*` tag or dispatching the build workflow builds both Python versions
for all four architectures and publishes the resulting packages to a GitHub
release. Manual dispatch accepts the destination release tag.
