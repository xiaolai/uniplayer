import unittest,importlib.util
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('package',ROOT/'scripts/check-torrent-runtime-package.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class RuntimePackageTests(unittest.TestCase):
 def test_exact_universal_portable_runtime(self):
  result=module.check(ROOT/'build/TorrentRuntime')
  self.assertTrue(result['hashesVerified']);self.assertEqual(set(result['architectures']),{'arm64','x86_64'})
