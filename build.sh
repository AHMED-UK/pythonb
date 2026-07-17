#!/usr/bin/env bash
#
# Standalone cross-compile of CPython for Termux, replicating the exact
# toolchain and configure flags used by termux-packages
# (scripts/build/toolchain/termux_setup_toolchain_29.sh + packages/python/build.sh).
#
# The source tarball is pre-patched (termux patches already applied):
#   https://github.com/zrsx/cpython3/releases/download/v3.13.14/Python-3.13.14.tar.xz
#
# Usage: TERMUX_ARCH=aarch64 ./build.sh
#
set -euo pipefail

##############################################################################
# Configuration matching termux-packages
##############################################################################
PYTHON_VERSION="3.13.14"
_MAJOR_VERSION="${PYTHON_VERSION%.*}"                 # 3.13
SRC_URL="https://github.com/zrsx/cpython3/releases/download/v${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
SRC_SHA256="188ba1dcd25510188a3cc8b40c7fcdd906cbd5b796bc7c1e3b94945f74aa9cbb"

# From scripts/properties.sh
TERMUX_NDK_VERSION="29"                               # NDK r29
TERMUX_PKG_API_LEVEL="24"                             # min android API level
TERMUX_PREFIX="/data/data/com.termux/files/usr"       # termux prefix

TERMUX_ARCH="${TERMUX_ARCH:-aarch64}"

# Termux dependency repo (official termux build dependencies system)
TERMUX_APT_URL="https://packages-cf.termux.dev/apt/termux-main"
# Runtime + build libs that python links against. Names match termux-main .debs.
TERMUX_DEPS=(
	gdbm libandroid-posix-semaphore libandroid-support libbz2 libcrypt
	libexpat libffi liblzma libsqlite ncurses ncurses-ui-libs openssl
	readline zlib zstd
)

WORKDIR="${WORKDIR:-$(pwd)/work-${TERMUX_ARCH}}"
DOWNLOADS="${DOWNLOADS:-$(pwd)/downloads}"
# Deliberately NOT using $ANDROID_NDK_HOME: GitHub runners preinstall a
# different NDK version. Termux pins r29, so we fetch exactly that.
NDK_HOME="${TERMUX_NDK_HOME:-$(pwd)/android-ndk-r${TERMUX_NDK_VERSION}}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"

##############################################################################
# Arch-specific variables (mirrors termux_step_setup_arch_variables)
##############################################################################
case "$TERMUX_ARCH" in
	aarch64) TERMUX_HOST_PLATFORM="aarch64-linux-android"; TERMUX_DEB_ARCH="aarch64" ;;
	arm)     TERMUX_HOST_PLATFORM="arm-linux-androideabi";  TERMUX_DEB_ARCH="arm" ;;
	i686)    TERMUX_HOST_PLATFORM="i686-linux-android";     TERMUX_DEB_ARCH="i686" ;;
	x86_64)  TERMUX_HOST_PLATFORM="x86_64-linux-android";   TERMUX_DEB_ARCH="x86_64" ;;
	*) echo "Invalid arch '$TERMUX_ARCH' (arm, i686, aarch64, x86_64)"; exit 1 ;;
esac

# The clang wrapper name embeds the API level; arm uses the armv7a triple.
if [ "$TERMUX_ARCH" = "arm" ]; then
	CLANG_TRIPLE="armv7a-linux-androideabi${TERMUX_PKG_API_LEVEL}"
else
	CLANG_TRIPLE="${TERMUX_HOST_PLATFORM}${TERMUX_PKG_API_LEVEL}"
fi

##############################################################################
# 1. Fetch NDK
##############################################################################
setup_ndk() {
	if [ -d "$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" ]; then
		echo "[*] Using existing NDK at $NDK_HOME"
		return
	fi
	echo "[*] Downloading Android NDK r${TERMUX_NDK_VERSION}..."
	local ndk_zip="$DOWNLOADS/android-ndk-r${TERMUX_NDK_VERSION}-linux.zip"
	mkdir -p "$DOWNLOADS"
	if [ ! -f "$ndk_zip" ]; then
		curl -fL --retry 3 -o "$ndk_zip" \
			"https://dl.google.com/android/repository/android-ndk-r${TERMUX_NDK_VERSION}-linux.zip"
	fi
	unzip -q "$ndk_zip" -d "$(dirname "$NDK_HOME")"
}

##############################################################################
# 2. Build a deps prefix from official termux .deb dependencies
##############################################################################
TOOLCHAIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="$TOOLCHAIN/sysroot"
# Host-side tree where termux debs are unpacked. Mirrors the termux prefix:
# headers/libs end up in $DEPS_PREFIX/include and $DEPS_PREFIX/lib.
# We point -isystem/-L here instead of polluting the (often read-only) NDK.
DEPS_ROOT=""   # set in setup_deps (depends on WORKDIR)
DEPS_PREFIX=""

setup_deps() {
	echo "[*] Fetching termux dependency debs for $TERMUX_DEB_ARCH..."
	mkdir -p "$DOWNLOADS/debs-${TERMUX_ARCH}" "$WORKDIR/deps"
	DEPS_ROOT="$WORKDIR/deps"
	DEPS_PREFIX="$DEPS_ROOT${TERMUX_PREFIX}"

	# Grab the Packages index to resolve exact .deb filenames.
	local pkgindex="$DOWNLOADS/Packages-${TERMUX_ARCH}"
	if [ ! -f "$pkgindex" ]; then
		curl -fL --retry 3 \
			-A 'Termux-Packages/1.0 (github-actions)' \
			"${TERMUX_APT_URL}/dists/stable/main/binary-${TERMUX_DEB_ARCH}/Packages" \
			-o "$pkgindex"
	fi

	for dep in "${TERMUX_DEPS[@]}"; do
		# Find the Filename: line for this package stanza.
		local fname
		fname=$(awk -v pkg="$dep" '
			$1=="Package:" {cur=$2}
			$1=="Filename:" && cur==pkg {print $2; exit}
		' "$pkgindex")
		if [ -z "$fname" ]; then
			echo "    [!] $dep not found in index, skipping"
			continue
		fi
		local deb="$DOWNLOADS/debs-${TERMUX_ARCH}/$(basename "$fname")"
		if [ ! -f "$deb" ]; then
			echo "    [+] $dep"
			curl -fsL --retry 3 "${TERMUX_APT_URL}/${fname}" -o "$deb"
		fi
		# Extract data.tar.* into the deps tree ("--no-same-owner/-permissions"
		# semantics: plain tar as non-root already avoids chown; use -m to skip
		# mtime restore so this also works on picky filesystems).
		local datatar
		datatar=$(ar t "$deb" | grep '^data\.tar' | head -1)
		case "$datatar" in
			data.tar.xz)  ar p "$deb" data.tar.xz  | tar xJm -C "$DEPS_ROOT" ;;
			data.tar.gz)  ar p "$deb" data.tar.gz  | tar xzm -C "$DEPS_ROOT" ;;
			data.tar.zst) ar p "$deb" data.tar.zst | tar --zstd -xm -C "$DEPS_ROOT" ;;
			*) echo "    [!] unknown data member '$datatar' in $deb"; exit 1 ;;
		esac
	done

	if [ ! -d "$DEPS_PREFIX/include" ] || [ ! -d "$DEPS_PREFIX/lib" ]; then
		echo "[!] Dependency extraction failed: $DEPS_PREFIX/{include,lib} missing"
		exit 1
	fi
	echo "    [ok] deps prefix at $DEPS_PREFIX"
}

##############################################################################
# 3. Fetch + verify source
##############################################################################
setup_source() {
	mkdir -p "$DOWNLOADS"
	local tarball="$DOWNLOADS/Python-${PYTHON_VERSION}.tar.xz"
	if [ ! -f "$tarball" ]; then
		echo "[*] Downloading pre-patched CPython source..."
		curl -fL --retry 3 -o "$tarball" "$SRC_URL"
	fi
	echo "[*] Verifying sha256..."
	echo "${SRC_SHA256}  ${tarball}" | sha256sum -c -
	rm -rf "$WORKDIR/src"
	mkdir -p "$WORKDIR/src"
	tar xf "$tarball" -C "$WORKDIR/src" --strip-components=1
}

##############################################################################
# 4. Toolchain env — replicates termux_setup_toolchain_29 exactly
##############################################################################
setup_toolchain_env() {
	export PATH="$TOOLCHAIN/bin:$PATH"

	export AS="${CLANG_TRIPLE}-clang"
	export CC="${CLANG_TRIPLE}-clang"
	export CPP="${CLANG_TRIPLE}-clang -E"
	export CXX="${CLANG_TRIPLE}-clang++"
	export LD="ld.lld"
	export AR="llvm-ar"
	export OBJCOPY="llvm-objcopy"
	export OBJDUMP="llvm-objdump"
	export RANLIB="llvm-ranlib"
	export READELF="llvm-readelf"
	export STRIP="llvm-strip"
	export NM="llvm-nm"
	export CC_FOR_BUILD="gcc"

	export CFLAGS=""
	export CPPFLAGS=""
	# Link against the unpacked termux deps; runtime search path is the
	# on-device termux lib dir (termux_setup_toolchain_29 lines 4, 34).
	export LDFLAGS="-L${DEPS_PREFIX}/lib"
	LDFLAGS+=" -Wl,-rpath=${TERMUX_PREFIX}/lib"

	# Arch-specific flags (termux_setup_toolchain_29 lines 43-65)
	case "$TERMUX_ARCH" in
		arm)
			CFLAGS+=" -march=armv7-a -mfpu=neon -mfloat-abi=softfp -mthumb"
			LDFLAGS+=" -march=armv7-a"
			;;
		i686)
			CFLAGS+=" -march=i686 -msse3 -mstackrealign -mfpmath=sse"
			CFLAGS+=" -fPIC"
			;;
	esac

	# Android 7+ DT_RUNPATH; avoid unneeded libs.
	LDFLAGS+=" -Wl,--enable-new-dtags"
	LDFLAGS+=" -Wl,--as-needed"

	# Basic hardening.
	CFLAGS+=" -fstack-protector-strong"
	LDFLAGS+=" -Wl,-z,relro,-z,now"

	# Release optimisation (termux uses -Oz by default).
	CFLAGS+=" -Oz"

	export CXXFLAGS="$CFLAGS"
	# Header include order: termux prefix (deps) first, then NDK sysroot
	# comes implicitly from the clang wrapper.
	export CPPFLAGS+=" -isystem${DEPS_PREFIX}/include"

	# python build.sh: libandroid-support is a dependency, link explicitly.
	LDFLAGS+=" -Wl,--no-as-needed,-landroid-support,--as-needed"
}

##############################################################################
# 5. Python-specific env/flags — replicates packages/python/build.sh
##############################################################################
python_configure_args() {
	# termux python build.sh: -O3 instead of -Oz for python itself.
	CFLAGS="${CFLAGS/-Oz/-O3}"
	# setup.py only probes gcc include paths; make zlib etc. discoverable.
	# (termux adds the standalone-toolchain sysroot; the stock NDK equivalent
	# is usr/include plus the per-triple lib dirs.)
	CPPFLAGS+=" -I${SYSROOT}/usr/include"
	# Keep symbols in libpython3.so.
	LDFLAGS="${LDFLAGS/-Wl,--as-needed/}"
	LDFLAGS+=" -L${SYSROOT}/usr/lib/${TERMUX_HOST_PLATFORM}/${TERMUX_PKG_API_LEVEL}"
	LDFLAGS+=" -L${SYSROOT}/usr/lib/${TERMUX_HOST_PLATFORM}"
	# multiprocessing posix semaphore lib.
	LDFLAGS+=" -landroid-posix-semaphore"
	export LIBCRYPT_LIBS="-lcrypt"

	export CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

	# Exactly the configure args from packages/python/build.sh.
	CONFIGURE_ARGS=(
		"ac_cv_file__dev_ptmx=yes"
		"ac_cv_file__dev_ptc=no"
		"ac_cv_func_wcsftime=no"
		"ac_cv_func_ftime=no"
		"ac_cv_func_faccessat=no"
		"--build=$(sh "$WORKDIR/src/config.guess" 2>/dev/null || echo x86_64-pc-linux-gnu)"
		"--host=${TERMUX_HOST_PLATFORM}"
		"--prefix=${TERMUX_PREFIX}"
		"--with-system-ffi"
		"--with-system-expat"
		"--without-ensurepip"
		"ac_cv_func_link=no"
		"ac_cv_func_linkat=no"
		"ac_cv_buggy_getaddrinfo=no"
		"--enable-loadable-sqlite-extensions"
		"ac_cv_little_endian_double=yes"
		"ac_cv_posix_semaphores_enabled=yes"
		"ac_cv_func_sem_open=yes"
		"ac_cv_func_sem_timedwait=yes"
		"ac_cv_func_sem_getvalue=yes"
		"ac_cv_func_sem_unlink=yes"
		"ac_cv_func_shm_open=yes"
		"ac_cv_func_shm_unlink=yes"
		"ac_cv_working_tzset=yes"
		"--with-build-python=python${_MAJOR_VERSION}"
		"ac_cv_header_sys_xattr_h=no"
		"ac_cv_func_getgrent=yes"
	)

	# API-level-gated args (termux build.sh termux_step_pre_configure).
	if [ "$TERMUX_PKG_API_LEVEL" -lt 28 ]; then
		CONFIGURE_ARGS+=("ac_cv_func_fexecve=no" "ac_cv_func_getlogin_r=no")
	fi
	if [ "$TERMUX_PKG_API_LEVEL" -lt 29 ]; then
		CONFIGURE_ARGS+=("ac_cv_func_getloadavg=no")
	fi
	if [ "$TERMUX_PKG_API_LEVEL" -lt 30 ]; then
		CONFIGURE_ARGS+=("ac_cv_func_sem_clockwait=no")
	fi
	if [ "$TERMUX_PKG_API_LEVEL" -lt 33 ]; then
		CONFIGURE_ARGS+=("ac_cv_func_preadv2=no" "ac_cv_func_pwritev2=no")
	fi
	if [ "$TERMUX_PKG_API_LEVEL" -lt 34 ]; then
		CONFIGURE_ARGS+=("ac_cv_func_close_range=no" "ac_cv_func_copy_file_range=no")
	fi
}

##############################################################################
# 6. Build
##############################################################################
build_python() {
	cd "$WORKDIR/src"
	echo "[*] Configuring for $TERMUX_ARCH ($TERMUX_HOST_PLATFORM), API $TERMUX_PKG_API_LEVEL"
	echo "    CFLAGS=$CFLAGS"
	echo "    LDFLAGS=$LDFLAGS"
	./configure "${CONFIGURE_ARGS[@]}"
	make -j"$(nproc)"
	rm -rf "$WORKDIR/install"
	make install DESTDIR="$WORKDIR/install"

	# Verify the important extension modules were built (termux post_massage check).
	local dynload="$WORKDIR/install${TERMUX_PREFIX}/lib/python${_MAJOR_VERSION}/lib-dynload"
	for module in _bz2 _curses _lzma _multiprocessing _sqlite3 _ssl zlib _zstd; do
		if ! ls "${dynload}/${module}".*.so >/dev/null 2>&1; then
			echo "[!] WARNING: python module '$module' was not built"
		else
			echo "    [ok] $module"
		fi
	done

	mkdir -p "$OUTPUT_DIR"
	local outname="python-${PYTHON_VERSION}-termux-${TERMUX_ARCH}.tar.xz"
	tar cJf "$OUTPUT_DIR/$outname" -C "$WORKDIR/install" .
	( cd "$OUTPUT_DIR" && sha256sum "$outname" > "${outname}.sha256" )
	echo "[*] Wrote $OUTPUT_DIR/$outname"
}

##############################################################################
main() {
	setup_ndk
	setup_source
	setup_deps
	setup_toolchain_env
	python_configure_args
	build_python
}
main "$@"
