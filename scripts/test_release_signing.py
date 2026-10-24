import base64
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import release_signing as signing


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'signing-state.json'
        self.env = {'RUNNER_TEMP': str(self.root), 'GITHUB_OUTPUT': str(self.root / 'output'),
                    'MACOS_CERTIFICATE_P12_BASE64': base64.b64encode(b'fake certificate').decode(),
                    'MACOS_CERTIFICATE_PASSWORD': 'fake-cert-password', 'APPLE_ID': 'fixture@example.invalid',
                    'APP_SPECIFIC_PASSWORD': 'fake-apple-password', 'TEAM_ID': 'FAKETEAM00'}
        self.calls = []

    def fake(self, args, message):
        self.calls.append(args)
        if args[:4] == ['security', 'list-keychains', '-d', 'user'] and len(args) == 4:
            return '"/fixture/login.keychain-db"\n"/Library/Keychains/System.keychain"\n'
        if args[1] == 'create-keychain':
            Path(args[-1]).touch()
        if args[1] == 'import':
            self.assertEqual(Path(args[2]).stat().st_mode & 0o777, 0o600)
            self.assertEqual(Path(args[2]).read_bytes(), b'fake certificate')
        return ''

    def test_setup_has_private_files_and_only_nonsecret_step_outputs(self):
        signing.setup(self.state, self.env, self.fake)
        state = json.loads(self.state.read_text())
        directory = Path(state['directory'])
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertFalse((directory / 'certificate.p12').exists())
        output = (self.root / 'output').read_text()
        self.assertIn('profile=uniplayer-ci-notary', output)
        for name in signing.REQUIRED:
            self.assertNotIn(self.env[name], output)
            self.assertNotIn(self.env[name], self.state.read_text())
        signing.cleanup(self.state, self.env, self.fake)
        self.assertFalse(directory.exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(self.calls[-2][:5], ['security', 'list-keychains', '-d', 'user', '-s'])
        self.assertEqual(self.calls[-1][:2], ['security', 'delete-keychain'])

    def test_import_failure_still_removes_certificate_and_can_restore_search_list(self):
        def fail(args, message):
            if args[1] == 'import':
                raise signing.SigningError(message)
            return self.fake(args, message)
        with self.assertRaises(signing.SigningError):
            signing.setup(self.state, self.env, fail)
        state = json.loads(self.state.read_text())
        self.assertFalse((Path(state['directory']) / 'certificate.p12').exists())
        signing.cleanup(self.state, self.env, self.fake)
        self.assertFalse(Path(state['directory']).exists())

    def test_cleanup_refuses_paths_outside_the_owned_temporary_directory(self):
        marker = self.root / 'important'
        marker.mkdir()
        self.state.write_text(json.dumps({'schema': 1, 'directory': str(marker),
                                         'keychain': str(marker / 'signing.keychain-db'), 'original': []}))
        with self.assertRaises(signing.SigningError):
            signing.cleanup(self.state, self.env, self.fake)
        self.assertTrue(marker.exists())
        self.assertEqual(self.calls, [])

    def test_cleanup_is_a_noop_before_setup(self):
        signing.cleanup(self.state, self.env, self.fake)
        self.assertEqual(self.calls, [])

    def test_missing_or_invalid_secret_is_reported_by_name_only(self):
        env = dict(self.env)
        env.pop('APPLE_ID')
        with self.assertRaisesRegex(signing.SigningError, 'APPLE_ID'):
            signing.credentials(env)
        env = dict(self.env, MACOS_CERTIFICATE_P12_BASE64='!!fake-invalid-secret!!')
        with self.assertRaises(signing.SigningError) as error:
            signing.credentials(env)
        self.assertNotIn('!!fake-invalid-secret!!', str(error.exception))

    def test_tool_errors_do_not_echo_credentials_or_apple_output(self):
        with patch.object(signing.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='fake-secret', stderr='fake-password')):
            with self.assertRaisesRegex(signing.SigningError, '^Import failed$'):
                signing.quiet(['security', 'import', 'fixture'], 'Import failed')


if __name__ == '__main__':
    unittest.main()
