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
	libexpat libffi liblzma libsqlite libuuid ncurses ncurses-ui-libs openssl
	readline zlib zstd
)

WORKDIR="${WORKDIR:-$(pwd)/work-${TERMUX_ARCH}}"
DOWNLOADS="${DOWNLOADS:-$(pwd)/downloads}"
# NDK resolution order (no download — termux-builder ships NDK r29 already):
#   1. $TERMUX_NDK_HOME (explicit override)
#   2. $NDK — set by termux-builder (scripts/properties.sh); the Dockerfile
#      exports NDK=/home/builder/lib/android-ndk-r29
#   3. termux-builder's default install path ${HOME}/lib/android-ndk-r29
#      (scripts/properties.sh: NDK="${HOME}/lib/android-ndk-r${TERMUX_NDK_VERSION}")
# Deliberately NOT $ANDROID_NDK_HOME: GitHub runners preinstall a different
# NDK version and termux pins r29.
NDK_HOME="${TERMUX_NDK_HOME:-${NDK:-${HOME}/lib/android-ndk-r${TERMUX_NDK_VERSION}}}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
# Vendored copy of termux-packages' ndk-patches/ (sysroot header fixes).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDK_PATCHES_DIR="$SCRIPT_DIR/ndk-patches"

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
# 1. Locate NDK (pre-installed by termux-builder — no download)
##############################################################################
setup_ndk() {
	if [ ! -d "$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64" ]; then
		echo "[!] NDK r${TERMUX_NDK_VERSION} not found at $NDK_HOME"
		echo "    termux-builder installs it via scripts/setup-android-sdk.sh;"
		echo "    otherwise set TERMUX_NDK_HOME or NDK to an existing NDK r${TERMUX_NDK_VERSION}."
		exit 1
	fi
	echo "[*] Using NDK at $NDK_HOME"
}

##############################################################################
# 1b. Patch the NDK sysroot headers the way termux does
#     (termux_setup_toolchain_29.sh lines 199-226). Without this, bionic's
#     headers contradict the forced ac_cv_* configure answers — e.g. grp.h
#     lacks the getgrent() stub that ac_cv_func_getgrent=yes relies on.
##############################################################################
patch_ndk_sysroot() {
	local sysroot="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
	local marker="$sysroot/.termux-ndk-patches-applied"
	if [ -f "$marker" ]; then
		echo "[*] NDK sysroot already patched (marker present)"
		return
	fi
	echo "[*] Applying termux ndk-patches to sysroot at $sysroot..."
	local termux_home="/data/data/com.termux/files/home"
	cd "$sysroot"
	for f in "$NDK_PATCHES_DIR/${TERMUX_NDK_VERSION}"/*.patch; do
		echo "    [+] $(basename "$f")"
		sed "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$f" | \
			sed "s%\@TERMUX_HOME\@%${termux_home}%g" | \
			patch --silent -p1
	done
	# libintl.h: inline gettext functions. langinfo.h: inline nl_langinfo().
	cp "$NDK_PATCHES_DIR"/{libintl.h,langinfo.h} usr/include

	# Remove headers termux removes: their functionality comes from termux
	# packages (zlib, libiconv, libandroid-glob...) or does not really exist
	# at API 24 (spawn.h). Leaving e.g. zlib.h/spawn.h in place makes
	# configure detect the wrong things.
	rm -f usr/include/{sys/{capability,shm,sem},{glob,iconv,spawn,zlib,zconf},KHR/khrplatform,execinfo}.h
	rm -rf usr/include/vulkan usr/include/{EGL,GLES,GLES2,GLES3}

	touch "$marker"
	cd - >/dev/null
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
# 2a. Cross-compile libmpdec for the target arch (--with-system-libmpdec).
#     Same version/recipe as termux-builder's scripts/setup-mpdec.sh, which
#     only builds aarch64 into the shared NDK sysroot; we build per-arch and
#     install into the deps prefix so all four arches get a matching library.
##############################################################################
MPDEC_VERSION="4.0.1"
MPDEC_SHA256="96d33abb4bb0070c7be0fed4246cd38416188325f820468214471938545b1ac8"
MPDEC_URL="https://www.bytereef.org/software/mpdecimal/releases/mpdecimal-${MPDEC_VERSION}.tar.gz"

setup_mpdec() {
	local tarball="$DOWNLOADS/mpdecimal-${MPDEC_VERSION}.tar.gz"
	mkdir -p "$DOWNLOADS"
	if [ ! -f "$tarball" ]; then
		echo "[*] Downloading mpdecimal ${MPDEC_VERSION}..."
		curl -fL --retry 3 -o "$tarball" "$MPDEC_URL"
	fi
	echo "${MPDEC_SHA256}  ${tarball}" | sha256sum -c -
	rm -rf "$WORKDIR/mpdecimal"
	mkdir -p "$WORKDIR/mpdecimal"
	tar xzf "$tarball" -C "$WORKDIR/mpdecimal" --strip-components=1

	echo "[*] Building libmpdec ${MPDEC_VERSION} for ${CLANG_TRIPLE}..."
	(
		cd "$WORKDIR/mpdecimal"
		export CC="$TOOLCHAIN/bin/${CLANG_TRIPLE}-clang"
		export CXX="$TOOLCHAIN/bin/${CLANG_TRIPLE}-clang++"
		export AR="$TOOLCHAIN/bin/llvm-ar"
		export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
		export STRIP="$TOOLCHAIN/bin/llvm-strip"
		# -fPIC so the static archive can be linked into _decimal*.so.
		export CFLAGS="-fPIC -O2"
		./configure --host="${TERMUX_HOST_PLATFORM}" --prefix="$DEPS_PREFIX"
		make -j"$(nproc)"
		make install
	)

	# Keep only the static library: the python tarball does not ship
	# libmpdec.so and no termux package provides it, so _decimal must link
	# libmpdec statically. Dropping the .so also shadows the aarch64-only
	# shared copy setup-mpdec.sh put in the NDK sysroot (-L deps wins).
	rm -f "$DEPS_PREFIX"/lib/libmpdec*.so*
	if [ ! -f "$DEPS_PREFIX/lib/libmpdec.a" ]; then
		echo "[!] libmpdec build failed: $DEPS_PREFIX/lib/libmpdec.a missing"
		exit 1
	fi
	echo "    [ok] libmpdec.a at $DEPS_PREFIX/lib"
}

##############################################################################
# 2b. Host "build python" — cross-compiling CPython requires a host python
#     of the same major.minor for --with-build-python. Replicates
#     termux_setup_build_python: minimal host build of the UPSTREAM tarball.
##############################################################################
BUILD_PYTHON_DIR="${BUILD_PYTHON_DIR:-$(pwd)/build-python-${PYTHON_VERSION}}"
UPSTREAM_SRC_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
UPSTREAM_SRC_SHA256="639e43243c620a308f968213df9e00f2f8f62332f7adbaa7a7eeb9783057c690"

setup_build_python() {
	if command -v "python${_MAJOR_VERSION}" >/dev/null 2>&1; then
		echo "[*] Host python${_MAJOR_VERSION} found: $(command -v python${_MAJOR_VERSION})"
		return
	fi
	local prefix="$BUILD_PYTHON_DIR/host-build-prefix"
	if [ ! -x "$prefix/bin/python${_MAJOR_VERSION}" ]; then
		echo "[*] Host-building minimal Python ${PYTHON_VERSION} for --with-build-python..."
		local tarball="$DOWNLOADS/Python-${PYTHON_VERSION}-upstream.tar.xz"
		mkdir -p "$DOWNLOADS"
		if [ ! -f "$tarball" ]; then
			curl -fL --retry 3 -o "$tarball" "$UPSTREAM_SRC_URL"
		fi
		echo "${UPSTREAM_SRC_SHA256}  ${tarball}" | sha256sum -c -
		rm -rf "$BUILD_PYTHON_DIR/src"
		mkdir -p "$BUILD_PYTHON_DIR/src"
		tar xf "$tarball" -C "$BUILD_PYTHON_DIR/src" --strip-components=1
		# Minimal host build, like termux_setup_build_python: clean env so
		# the android cross vars set later can never leak in.
		(
			cd "$BUILD_PYTHON_DIR/src"
			mkdir -p host-build
			cd host-build
			env -i PATH="/usr/local/bin:/usr/bin:/bin" \
				LDFLAGS="-Wl,-rpath=$prefix/lib" \
				../configure \
					--with-ensurepip=install \
					--enable-shared \
					--prefix="$prefix"
			env -i PATH="/usr/local/bin:/usr/bin:/bin" \
				make -j "$(nproc)" install
		)
	fi
	export PATH="$prefix/bin:$PATH"
	"python${_MAJOR_VERSION}" --version
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

	# Build with C17 instead of the default C11. configure hard-codes the
	# standard in the generated script and its source; patch both so a
	# stray reconfigure keeps the change.
	echo "[*] Switching C standard c11 -> c17 in configure/configure.ac..."
	sed -i 's/-std=c11/-std=c17/g' "$WORKDIR/src/configure" "$WORKDIR/src/configure.ac"
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

	# CPython 3.13 detects _zstd only via pkg-config (PKG_CHECK_MODULES).
	# The termux .pc files carry prefix=$TERMUX_PREFIX (the on-device path),
	# so point pkg-config at the deps pkgconfig dir and use SYSROOT_DIR to
	# rebase those prefixes into the extracted deps tree.
	export PKG_CONFIG_LIBDIR="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/share/pkgconfig"
	export PKG_CONFIG_SYSROOT_DIR="${DEPS_ROOT}"
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

	# ThinLTO: cache backend compilations so incremental relinks are cheap.
	# (--with-lto=thin below adds -flto=thin itself via *_NODIST flags;
	# lld runs the LTO backends in parallel across all cores by default.)
	mkdir -p "$WORKDIR/thinlto-cache"
	LDFLAGS+=" -Wl,--thinlto-cache-dir=$WORKDIR/thinlto-cache"

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
		# libmpdec is cross-compiled per-arch into the deps prefix by
		# setup_mpdec (static-only), mirroring termux-builder's
		# scripts/setup-mpdec.sh.
		"--with-system-libmpdec"
		# ThinLTO for python/libpython (clang + ld.lld + llvm-ar/ranlib are
		# already in use, which is exactly what configure's LTO check needs).
		# libmpdec.a stays non-LTO object code; lld links mixed inputs fine.
		"--with-lto=thin"
		"--without-ensurepip"
		"ac_cv_func_link=no"
		"ac_cv_func_linkat=no"
		"ac_cv_buggy_getaddrinfo=no"
		"--enable-loadable-sqlite-extensions"
		"--disable-test-modules"
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
	for module in _bz2 _curses _decimal _lzma _multiprocessing _sqlite3 _ssl zlib _zstd; do
		if ! ls "${dynload}/${module}".*.so >/dev/null 2>&1; then
			echo "[!] WARNING: python module '$module' was not built"
		else
			echo "    [ok] $module"
		fi
	done

	build_deb
}

##############################################################################
# 6a. Assemble a Termux .deb from the DESTDIR install tree.
#     A Debian package is an `ar` archive of three members, in order:
#       debian-binary, control.tar.xz, data.tar.xz
#     Termux installs debs with dpkg, so the data tree must be rooted at "."
#     with paths under the termux prefix (which DESTDIR already gives us).
##############################################################################
# Runtime dependencies python links against (libmpdec is static, so omitted).
DEB_DEPENDS="gdbm, libandroid-posix-semaphore, libandroid-support, libbz2, libcrypt, libexpat, libffi, liblzma, libsqlite, libuuid, ncurses, openssl, readline, zlib, zstd"
DEB_MAINTAINER="${DEB_MAINTAINER:-Termux <root@localhost>}"

build_deb() {
	local install_root="$WORKDIR/install"
	local pkgroot="$WORKDIR/deb"
	rm -rf "$pkgroot"
	mkdir -p "$pkgroot"

	# Installed-Size is in KiB (Debian convention).
	local installed_size
	installed_size=$(du -sk "$install_root" | cut -f1)

	# control.tar.xz — DEBIAN/control describing the package.
	mkdir -p "$pkgroot/control"
	cat > "$pkgroot/control/control" <<EOF
Package: python3.13
Version: ${PYTHON_VERSION}
Architecture: ${TERMUX_DEB_ARCH}
Maintainer: ${DEB_MAINTAINER}
Installed-Size: ${installed_size}
Depends: ${DEB_DEPENDS}
Homepage: https://www.python.org/
Description: Python programming language (CPython ${PYTHON_VERSION}) for Termux
 Cross-compiled with the same toolchain and configure flags as
 termux-packages (NDK r${TERMUX_NDK_VERSION}, API ${TERMUX_PKG_API_LEVEL}).
EOF
	tar cJf "$pkgroot/control.tar.xz" -C "$pkgroot/control" .

	# data.tar.xz — the file tree, paths relative to "/".
	tar cJf "$pkgroot/data.tar.xz" -C "$install_root" .

	# debian-binary — format version.
	echo "2.0" > "$pkgroot/debian-binary"

	mkdir -p "$OUTPUT_DIR"
	local outname="python_${PYTHON_VERSION}_${TERMUX_DEB_ARCH}.deb"
	# Order matters: debian-binary must be the first ar member.
	( cd "$pkgroot" && ar rc "$OUTPUT_DIR/$outname" debian-binary control.tar.xz data.tar.xz )
	( cd "$OUTPUT_DIR" && sha256sum "$outname" > "${outname}.sha256" )
	echo "[*] Wrote $OUTPUT_DIR/$outname"
}

##############################################################################
main() {
	setup_ndk
	patch_ndk_sysroot
	setup_build_python
	setup_source
	setup_deps
	setup_mpdec
	setup_toolchain_env
	python_configure_args
	build_python
}
main "$@"
