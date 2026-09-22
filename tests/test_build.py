import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFIX = "data/data/com.termux/files/usr"
VERSIONS = ("3.13.15", "3.14.7")
ARCHES = ("aarch64", "arm", "i686", "x86_64")
MODULES = (
    "_bz2", "_curses", "_decimal", "_hashlib", "_lzma",
    "_multiprocessing", "_sqlite3", "_ssl", "zlib", "_zstd",
)


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pythonb-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.work = self.base / "work"
        self.deps = self.work / "deps" / PREFIX
        self.install = self.work / "install" / PREFIX
        self.downloads = self.base / "downloads"
        self.output = self.base / "output"
        self.env = os.environ.copy()
        self.env.update(
            WORKDIR=str(self.work), DOWNLOADS=str(self.downloads),
            OUTPUT_DIR=str(self.output), TERMUX_NDK_HOME=str(self.base / "ndk"),
            BUILD_PYTHON_DIR=str(self.base / "host-python"),
            TERMUX_ARCH="i686", PYTHON_VERSION="3.13.15",
        )

    def run_build(self, script, **env):
        return subprocess.run(
            ["bash", "-c", 'source "$1"\n' + script, "test", str(ROOT / "build.sh")],
            env={**self.env, **env}, cwd=ROOT, text=True, capture_output=True,
        )

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def create_openssl(self):
        (self.deps / "include/openssl").mkdir(parents=True)
        (self.deps / "include/openssl/ssl.h").touch()
        lib = self.deps / "lib"
        lib.mkdir()
        for name in ("libcrypto", "libssl"):
            (lib / f"{name}.so.3").write_bytes(b"OpenSSL fixture")
            (lib / f"{name}.so").symlink_to(f"{name}.so.3")

    def test_libxcrypt_cleanup_preserves_openssl(self):
        self.create_openssl()
        lib = self.deps / "lib"
        for name in ("libcrypt", "libxcrypt"):
            (lib / f"{name}.so.2").touch()
            (lib / f"{name}.so").symlink_to(f"{name}.so.2")
        (lib / "libcrypt.a").touch()
        source = self.base / "libxcrypt-fixture"
        source.mkdir()
        configure = source / "configure"
        configure.write_text("#!/bin/sh\nexit 0\n")
        configure.chmod(0o755)
        self.downloads.mkdir()
        archive = self.downloads / "libxcrypt-4.5.2.tar.xz"
        with tarfile.open(archive, "w:xz") as tar:
            tar.add(source, arcname="libxcrypt-4.5.2")
        result = self.run_build('''
DEPS_PREFIX="$WORKDIR/deps$TERMUX_PREFIX"
LIBXCRYPT_SHA256=$(sha256sum "$DOWNLOADS/libxcrypt-${LIBXCRYPT_VERSION}.tar.xz")
LIBXCRYPT_SHA256=${LIBXCRYPT_SHA256%% *}
# Exercise the real extraction and cleanup, replacing only compilation.
make() { :; }
setup_libxcrypt
check_openssl_deps
''')
        self.assert_success(result)
        for name in ("libcrypto", "libssl"):
            self.assertEqual((lib / f"{name}.so").read_bytes(), b"OpenSSL fixture")
        for name in ("libcrypt", "libxcrypt"):
            self.assertFalse((lib / f"{name}.so").is_symlink())
            self.assertFalse((lib / f"{name}.so.2").exists())
        self.assertTrue((lib / "libcrypt.a").exists())

    def test_broken_openssl_symlink_fails_preflight(self):
        self.create_openssl()
        (self.deps / "lib/libcrypto.so.3").unlink()
        result = self.run_build('''
DEPS_PREFIX="$WORKDIR/deps$TERMUX_PREFIX"
check_openssl_deps
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libcrypto.so", result.stdout)

    def test_configure_matrix_uses_staged_openssl_and_device_rpath(self):
        for version in VERSIONS:
            for arch in ARCHES:
                with self.subTest(version=version, arch=arch):
                    result = self.run_build('''
DEPS_ROOT="$WORKDIR/deps"
DEPS_PREFIX="$DEPS_ROOT$TERMUX_PREFIX"
setup_toolchain_env
python_configure_args
printf '%s\n' "$LDFLAGS" "${CONFIGURE_ARGS[@]}"
''', PYTHON_VERSION=version, TERMUX_ARCH=arch)
                    self.assert_success(result)
                    lines = result.stdout.splitlines()
                    flags = lines[0].split()
                    self.assertIn(f"-L{self.deps}/lib", flags)
                    self.assertNotIn("-lcrypto", flags)
                    self.assertNotIn("-lssl", flags)
                    self.assertNotIn("opt/aosp", result.stdout)
                    self.assertIn(f"--with-openssl={self.deps}", lines)
                    self.assertIn(f"--with-openssl-rpath=/{PREFIX}/lib", lines)

    def test_module_gate_stops_packaging(self):
        source = self.work / "src"
        source.mkdir(parents=True)
        configure = source / "configure"
        configure.write_text("#!/bin/sh\nexit 0\n")
        configure.chmod(0o755)
        for version in VERSIONS:
            minor = version.rsplit(".", 1)[0]
            dynload = self.install / f"lib/python{minor}/lib-dynload"
            dynload.mkdir(parents=True)
            for module in MODULES:
                (dynload / f"{module}.cpython-fixture.so").touch()
            for missing in ("_ssl", "_hashlib", "_zstd", None):
                with self.subTest(version=version, missing=missing):
                    path = dynload / f"{missing}.cpython-fixture.so"
                    if missing:
                        path.unlink()
                    result = self.run_build('''
CFLAGS= CPPFLAGS= CXXFLAGS= LDFLAGS=
CONFIGURE_ARGS=()
# Keep the fixture install tree; run the real build/module-gate sequence.
make() { :; }
rm() { :; }
build_deb() { echo PACKAGED; }
build_python
''', PYTHON_VERSION=version)
                    if missing:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn("PACKAGED", result.stdout)
                        self.assertIn(f"module '{missing}'", result.stdout)
                        path.touch()
                    else:
                        self.assert_success(result)
                        self.assertIn("PACKAGED", result.stdout)

    def test_empty_install_fails_module_gate(self):
        result = self.run_build("check_python_modules")
        self.assertNotEqual(result.returncode, 0)
        for module in MODULES:
            self.assertIn(f"module '{module}'", result.stdout)

    def test_missing_required_dependency_fails(self):
        self.downloads.mkdir()
        (self.downloads / "Packages-i686").write_text("")
        result = self.run_build("setup_deps")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Required dependency", result.stdout)

    def test_deb_declares_installation_conflicts(self):
        (self.install / "bin").mkdir(parents=True)
        (self.install / "bin/python3").write_bytes(b"fixture")
        for version, other in (("3.13.15", "3.14"), ("3.14.7", "3.13")):
            with self.subTest(version=version):
                result = self.run_build("build_deb", PYTHON_VERSION=version)
                self.assert_success(result)
                archive = self.output / f"python_{version}_i686.deb"
                fields = subprocess.check_output(
                    ["dpkg-deb", "--field", str(archive)], text=True,
                )
                self.assertIn(f"Package: python{version.rsplit('.', 1)[0]}\n", fields)
                self.assertIn(f"Conflicts: python, python{other}\n", fields)
                self.assertIn("ncurses-ui-libs", fields)
                checksum = subprocess.run(
                    ["sha256sum", "-c", archive.name + ".sha256"],
                    cwd=self.output, text=True, capture_output=True,
                )
                self.assert_success(checksum)


if __name__ == "__main__":
    unittest.main()
