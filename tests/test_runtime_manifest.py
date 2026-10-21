"""The runtime manifest (docs/ultimate-app-blueprint.md §3): generator and parser agree, the header holds only pinned
version constants, and the production RomFS / shared-font code stops on a tampered font, index or image. No game data."""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / 'games/totk'
sys.path.insert(0, str(GAME / 'scripts'))
import prepare_romfs_backend as backend   # noqa: E402
import prepare_runtime_manifest as rm     # noqa: E402

SANITIZE = ['-fsanitize=undefined', '-fno-sanitize-recover=all']
_compiler_cache = {}


def sanitizing_compiler():
    """The first C compiler that links a UBSan program here (Apple clang on a Mac; gcc where clang lacks the runtime)."""
    if 'cc' in _compiler_cache:
        return _compiler_cache['cc']
    found = None
    with tempfile.TemporaryDirectory() as d:
        probe = Path(d) / 'p.c'
        probe.write_text('int main(void){return 0;}\n')
        for name in ('cc', 'clang', 'gcc'):
            path = shutil.which(name)
            if path and subprocess.run([path, *SANITIZE, str(probe), '-o', str(Path(d) / 'p')],
                                       capture_output=True).returncode == 0 \
                    and subprocess.run([str(Path(d) / 'p')]).returncode == 0:
                found = path
                break
    _compiler_cache['cc'] = found
    return found


def compile_c(compiler, sources, output, *flags):
    r = subprocess.run([compiler, '-std=c11', '-g', '-Wall', '-Wextra', '-Werror', *SANITIZE, *flags,
                        *map(str, sources), '-o', str(output)], capture_output=True, text=True)
    if r.returncode:
        raise AssertionError(r.stdout + r.stderr)
    return output


def font_bytes(kind, size=64):
    """A structurally valid BFTTF-shaped file (the runtime checks only size and SHA-256)."""
    body = bytes((kind * 37 + i) & 0xFF for i in range(size - 8))
    return struct.pack('>II', 0x7F9A0218, (size - 8) ^ 0x7F9A0218) + body


def make_fonts(folder, sizes=(64, 72, 80, 88, 96, 104)):
    folder.mkdir(parents=True, exist_ok=True)
    rows = []
    for kind, size in enumerate(sizes):
        data = font_bytes(kind, size)
        name = f'font{kind}'
        (folder / f'{kind}-{name}.bfttf').write_bytes(data)
        rows.append(dict(type=kind, name=name, bfttf_bytes=size, font_bytes=size - 8,
                         sha256=hashlib.sha256(data).hexdigest()))
    (folder / 'manifest.json').write_text(json.dumps(dict(status='pass', fonts=rows)))
    return rows


FILES = {'a.txt': b'hello from a synthetic RomFS\n', 'b/c.bin': bytes(range(256)) * 3, 'd.txt': b'last'}


def make_romfs(root, version='v0'):
    """extracted/<version>/romfs with romfs.bin and an index.json like extract_romfs.py writes, plus a matching
    expected-v*.json in root/assets."""
    folder = root / f'extracted/{version}/romfs'
    folder.mkdir(parents=True)
    image, files = bytearray(), []
    for path in sorted(FILES):
        files.append(dict(path=path, offset=len(image), size=len(FILES[path])))
        image += FILES[path]
        image += b'\0' * (-len(image) % 16)
    (folder / 'romfs.bin').write_bytes(image)
    digest = hashlib.sha256(image).hexdigest()
    (folder / 'index.json').write_text(json.dumps(dict(status='pass', romfs_size=len(image), romfs_sha256=digest,
                                                       files=files)))
    assets = root / 'assets'
    assets.mkdir(exist_ok=True)
    (assets / backend.EXPECTED_FILES[version]).write_text(json.dumps(dict(romfs=dict(size=len(image), sha256=digest))))
    return folder, assets, len(image), digest


class Parser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cc = sanitizing_compiler()
        cls.tmp = tempfile.TemporaryDirectory()
        if cls.cc:
            cls.exe = compile_c(cls.cc, [ROOT / 'tests/test_runtime_manifest.c'], Path(cls.tmp.name) / 'trm')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        if not self.cc:
            self.skipTest('no C compiler that links -fsanitize=undefined')

    def test_native_cases_under_ubsan(self):
        r = subprocess.run([str(self.exe)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, r'\d+ runtime manifest cases passed')

    def native_parse(self, text):
        path = Path(self.tmp.name) / 'm.txt'
        path.write_bytes(text.encode() if isinstance(text, str) else text)
        return subprocess.run([str(self.exe), 'parse', str(path)], capture_output=True, text=True)

    def fonts(self):
        return [dict(path=f'extracted/firmware/shared-fonts/{k}-font{k}.bfttf', file_bytes=100 + k * 1000,
                     font_bytes=92 + k * 1000, sha256=hashlib.sha256(bytes([k])).hexdigest()) for k in range(6)]

    def test_generator_and_parser_agree(self):
        index = hashlib.sha256(b'index').hexdigest()
        text = rm.render(index, self.fonts())
        r = self.native_parse(text)
        self.assertEqual(r.returncode, 0, r.stdout)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], f'romfs_index_sha256\t{index}')
        for k, (line, font) in enumerate(zip(lines[1:], self.fonts())):
            self.assertEqual(line, f'font\t{k}\t{font["path"]}\t{font["file_bytes"]}\t{font["font_bytes"]}\t{font["sha256"]}')
        self.assertEqual(rm.parse(text), (index, self.fonts()))

    def test_both_parsers_reject_the_same_malformed_input(self):
        good = rm.render('a' * 64, self.fonts())
        bad = [good[:-1], good + '\n', good.replace('format\t1', 'format\t2'), good.replace('\n', '\r\n'),
               good.replace('\t100\t92\t', '\t100\t93\t'), good.replace('\t100\t92\t', '\t0100\t92\t'),
               good.replace('extracted/', '/extracted/', 1), good.replace('extracted/', '../', 1),
               good.replace('font\t1\t', 'font\t2\t', 1), good.replace('a' * 64, 'A' * 64),
               '\n'.join(good.split('\n')[:-2]) + '\n', good + 'font\t6\tx\t9\t1\t' + 'b' * 64 + '\n']
        for text in bad:
            with self.subTest(text=text[:60]):
                self.assertNotEqual(self.native_parse(text).returncode, 0)
                with self.assertRaises(rm.ManifestError):
                    rm.parse(text)

    def test_generator_refuses_what_the_parser_would_refuse(self):
        fonts = self.fonts()
        for key, value in [('path', '/abs'), ('path', 'a/../b'), ('path', 'a\tb'), ('file_bytes', 8),
                           ('font_bytes', 1), ('sha256', 'x' * 64), ('file_bytes', (64 << 20) + 1)]:
            broken = [dict(f) for f in fonts]
            broken[3][key] = value
            if key == 'file_bytes' and value > 8:
                broken[3]['font_bytes'] = value - 8
            with self.subTest(key=key, value=value), self.assertRaises(rm.ManifestError):
                rm.render('a' * 64, broken)
        with self.assertRaises(rm.ManifestError):
            rm.render('a' * 64, fonts[:5])


class Generators(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_headers_come_from_the_checked_in_expectations_alone(self):
        for version, name in backend.EXPECTED_FILES.items():
            expected = json.loads((GAME / 'assets' / name).read_text())['romfs']
            path = backend.write_header(version, root=self.root)
            self.assertEqual(path.read_text(), f'#define ROMFS_IMAGE_SIZE {expected["size"]}ULL\n'
                                               f'#define ROMFS_IMAGE_SHA256 "{expected["sha256"]}"\n')
        self.assertFalse((self.root / 'extracted').exists(), 'a header must not need player data')
        # The header no longer carries the player's index digest.
        self.assertNotIn('INDEX', (self.root / 'build/romfs_config.h').read_text())

    def test_header_only_cli_needs_no_player_data(self):
        r = subprocess.run([sys.executable, str(GAME / 'scripts/prepare_romfs_backend.py'), '--header-only',
                            '--version', 'v143'], capture_output=True, text=True, cwd=self.root)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_index_requires_the_pinned_romfs(self):
        folder, assets, size, digest = make_romfs(self.root)
        files, _ = backend.build_index('v0', root=self.root, assets=assets)
        self.assertEqual(files, len(FILES))
        index = (folder / 'runtime-index.bin').read_bytes()
        self.assertEqual(index[:8], b'TOTKRFS1')
        # Another image than the pinned one stops the build.
        (assets / 'expected-v1.0.0.json').write_text(json.dumps(dict(romfs=dict(size=size, sha256='0' * 64))))
        with self.assertRaisesRegex(backend.RomfsError, 'not the pinned'):
            backend.build_index('v0', root=self.root, assets=assets)
        # The right digest but a truncated image on disk stops it too.
        (assets / 'expected-v1.0.0.json').write_text(json.dumps(dict(romfs=dict(size=size, sha256=digest))))
        with open(folder / 'romfs.bin', 'r+b') as f:
            f.truncate(size - 1)
        with self.assertRaisesRegex(backend.RomfsError, 'bytes, not'):
            backend.build_index('v0', root=self.root, assets=assets)

    def test_index_rejects_unsorted_paths_and_out_of_bounds_files(self):
        with self.assertRaisesRegex(backend.RomfsError, 'sorted'):
            backend.index_bytes([dict(path='b', offset=0, size=1), dict(path='a', offset=0, size=1)])
        folder, assets, size, _ = make_romfs(self.root)
        data = json.loads((folder / 'index.json').read_text())
        data['files'][0]['size'] = size + 1
        (folder / 'index.json').write_text(json.dumps(data))
        with self.assertRaisesRegex(backend.RomfsError, 'outside the image'):
            backend.build_index('v0', root=self.root, assets=assets)

    def test_manifest_binds_the_fonts_actual_bytes(self):
        folder, assets, _, _ = make_romfs(self.root)
        backend.build_index('v0', root=self.root, assets=assets)
        fonts = self.root / 'extracted/firmware/shared-fonts'
        make_fonts(fonts)
        path = rm.write(folder, fonts, self.root)
        index_sha, rows = rm.parse(path.read_text())
        self.assertEqual(index_sha, hashlib.sha256((folder / 'runtime-index.bin').read_bytes()).hexdigest())
        self.assertEqual(rows[2]['path'], 'extracted/firmware/shared-fonts/2-font2.bfttf')
        # A changed font byte (same size) no longer matches its folder manifest.
        target = fonts / '2-font2.bfttf'
        data = bytearray(target.read_bytes())
        data[20] ^= 1
        target.write_bytes(bytes(data))
        with self.assertRaisesRegex(rm.ManifestError, 'do not match'):
            rm.write(folder, fonts, self.root)

    def test_manifest_needs_the_index_and_fonts_inside_the_tree(self):
        folder, assets, _, _ = make_romfs(self.root)
        fonts = self.root / 'extracted/firmware/shared-fonts'
        make_fonts(fonts)
        with self.assertRaisesRegex(rm.ManifestError, 'prepare_romfs_backend'):
            rm.write(folder, fonts, self.root)
        backend.build_index('v0', root=self.root, assets=assets)
        outside = Path(tempfile.mkdtemp())
        try:
            make_fonts(outside / 'fonts')
            with self.assertRaisesRegex(rm.ManifestError, 'inside'):
                rm.write(folder, outside / 'fonts', self.root)
        finally:
            shutil.rmtree(outside)

    def test_cli_writes_the_manifest(self):
        folder, assets, _, _ = make_romfs(self.root)
        backend.build_index('v0', root=self.root, assets=assets)
        make_fonts(self.root / 'extracted/firmware/shared-fonts')
        r = subprocess.run([sys.executable, str(GAME / 'scripts/prepare_runtime_manifest.py'), '--root', str(self.root)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((folder / rm.NAME).is_file())


class ProductionRuntime(unittest.TestCase):
    """runtime/romfs.c and runtime/shared_font.c themselves, started against a synthetic RomFS."""

    def setUp(self):
        self.cc = sanitizing_compiler()
        if not self.cc:
            self.skipTest('no C compiler that links -fsanitize=undefined')
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.romfs, assets, size, digest = make_romfs(self.root)
        backend.build_index('v0', root=self.root, assets=assets)
        self.fonts = self.root / 'extracted/firmware/shared-fonts'
        self.rows = make_fonts(self.fonts)
        rm.write(self.romfs, self.fonts, self.root)
        gen = self.root / 'gen'
        gen.mkdir()
        (gen / 'romfs_config.h').write_text(backend.header_text(size, digest))
        # The runtime's dense one-line style trips gcc's indentation heuristic, which Apple clang does not have.
        flags = ['-D_GNU_SOURCE', '-Wno-misleading-indentation', f'-I{gen}', f'-I{GAME / "runtime"}', f'-I{GAME / "third_party/d2r_gfx/gfx/nvn/include"}']
        if sys.platform != 'darwin':
            # CommonCrypto and the locale lookup are macOS frameworks; the harness brings small stand-ins, and Linux
            # names the stat timestamps differently.
            flags = ['-D_GNU_SOURCE', f'-I{ROOT / "tests/runtime_manifest/compat"}', *flags[1:],
                     '-Dst_mtimespec=st_mtim', '-Dst_ctimespec=st_ctim', '-Dst_birthtimespec=st_ctim', '-pthread']
        else:
            # totk_ui_lang.h's inline locale lookup calls CoreFoundation, so the harness must link it.
            flags += ['-Wno-deprecated-declarations', '-framework', 'CoreFoundation']
        self.exe = compile_c(self.cc, [ROOT / 'tests/runtime_manifest/harness.c', GAME / 'runtime/romfs.c',
                                       GAME / 'runtime/shared_font.c', GAME / 'runtime/runtime_manifest.c'],
                             self.root / 'harness', *flags)

    def tearDown(self):
        self.tmp.cleanup()

    def start(self):
        proof = self.root / 'proof'
        proof.mkdir(exist_ok=True)
        return subprocess.run([str(self.exe), str(self.romfs), str(proof)], capture_output=True, text=True,
                              cwd=self.root, env=dict(os.environ, TOTK_ROMFS_VERIFY='full'))

    def assertStops(self, message):
        r = self.start()
        self.assertEqual(r.returncode, 7, r.stdout + r.stderr)
        self.assertIn(message, r.stderr)

    def test_starts_with_a_matching_manifest(self):
        r = self.start()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f'fonts={sum(row["font_bytes"] for row in self.rows)}', r.stdout)
        self.assertIn(f'first={len(FILES["a.txt"])}:{FILES["a.txt"].decode()}', r.stdout)

    def test_tampered_font_stops_the_game(self):
        target = self.fonts / '4-font4.bfttf'
        data = bytearray(target.read_bytes())
        data[-1] ^= 0xFF
        target.write_bytes(bytes(data))
        self.assertStops('shared font integrity mismatch')

    def test_resized_font_stops_the_game(self):
        target = self.fonts / '0-font0.bfttf'
        target.write_bytes(target.read_bytes() + b'x')
        self.assertStops('shared font size')

    def test_tampered_romfs_image_stops_the_game(self):
        image = self.romfs / 'romfs.bin'
        data = bytearray(image.read_bytes())
        data[3] ^= 1
        image.write_bytes(bytes(data))
        self.assertStops('RomFS integrity mismatch')

    def test_tampered_index_stops_the_game(self):
        index = self.romfs / 'runtime-index.bin'
        data = bytearray(index.read_bytes())
        data[-2] ^= 1   # a byte of a name: the layout stays valid, only the digest catches it
        index.write_bytes(bytes(data))
        self.assertStops('RomFS integrity mismatch')

    def test_missing_or_malformed_manifest_stops_the_game(self):
        manifest = self.romfs / rm.NAME
        text = manifest.read_text()
        manifest.write_text(text.replace('format\t1', 'format\t9'))
        self.assertStops('runtime manifest missing or invalid')
        manifest.unlink()
        self.assertStops('runtime manifest missing or invalid')

    def test_manifest_with_another_font_digest_stops_the_game(self):
        manifest = self.romfs / rm.NAME
        index_sha, fonts = rm.parse(manifest.read_text())
        fonts[1]['sha256'] = '0' * 64
        manifest.write_text(rm.render(index_sha, fonts))
        self.assertStops('shared font integrity mismatch')


if __name__ == '__main__':
    unittest.main()
