"""A Release candidate must fail before signing if its torrent runtime is absent."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ReleaseRuntimeGateTests(unittest.TestCase):
    def test_missing_runtime_cannot_reach_signing(self):
        executable = ROOT / 'build/TorrentRuntime/TorrentRuntimeSupervisor'
        if not executable.exists():
            self.skipTest('Build the pinned universal runtime first')
        config = dict(line.split(' = ', 1) for line in (ROOT / 'Configs/Deployment.xcconfig').read_text().splitlines() if ' = ' in line)
        with tempfile.TemporaryDirectory(prefix='UniPlayerReleaseGate-') as temporary:
            base = Path(temporary)
            app = base / 'derived/Build/Products/Release/UniPlayer.app/Contents'
            (app / 'MacOS').mkdir(parents=True)
            shutil.copy2(executable, app / 'MacOS/UniPlayer')
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':config['MARKETING_VERSION'], 'CFBundleVersion':config['CURRENT_PROJECT_VERSION']}))
            # Satisfy the earlier release gate so this fixture reaches the
            # runtime check it exists to exercise.
            (app / 'Resources').mkdir()
            (app / 'Resources/NetflixRatings.js').write_text('uniPlayerRatings')
            result = subprocess.run(['python3', str(ROOT / 'scripts/release-macos.py'), '--build', config['CURRENT_PROJECT_VERSION'], '--sign-only', '--skip-build', '--identity', 'Developer ID Application: missing-runtime-test', '--derived-data', str(base / 'derived'), '--output', str(base / 'candidate')], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('TorrentRuntime is required in every candidate', result.stderr)
            self.assertNotIn('Running: codesign', result.stdout)
            self.assertFalse((base / 'candidate/candidate.json').exists())

if __name__ == '__main__':
    unittest.main()
