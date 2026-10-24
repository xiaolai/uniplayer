import base64
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import release_local as local
import github_release as release
import test_github_release as fixtures


class LocalReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        (self.root / 'Configs').mkdir()
        (self.root / 'Configs/Deployment.xcconfig').write_text('MARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 15\n')
        (self.root / 'RELEASE_NOTES.md').write_text('## 0.2.0 (unreleased)\n\nFixture notes\n')
        self.git('add', '.')
        tree = self.git('write-tree')
        self.source = self.git('commit-tree', tree, '-m', 'Synthetic local release fixture')
        self.git('update-ref', 'refs/heads/main', self.source)
        self.git('symbolic-ref', 'HEAD', 'refs/heads/main')
        self.git('remote', 'add', 'origin', 'git@github.com:xiaolai/uniplayer.git')
        self.plan = local.plan_for(self.root, Path(self.temporary.name) / 'artifacts')
        self.hub = fixtures.FakeHub()
        self.hub.tap_repository = 'xiaolai/homebrew-tap'
        self.hub.api = self.api

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'user.name=Fixture', '-c',
                                        'user.email=fixture@example.invalid', *args], cwd=self.root,
                                       text=True, stderr=subprocess.DEVNULL).strip()

    def api(self, path, **kwargs):
        if '/git/ref/heads/main' in path:
            return {'object': {'sha': self.source}}
        if '/git/ref/tags/' in path:
            return None
        if '/commits/' in path:
            raise release.APIError(422)
        return {'permissions': {'push': True}}

    def test_source_requires_clean_main_and_never_commits_or_stashes(self):
        local.assert_source(self.plan)
        (self.root / 'untracked-source').write_text('pending')
        with self.assertRaisesRegex(release.ReleaseError, 'never stashes or commits'):
            local.assert_source(self.plan)
        (self.root / 'untracked-source').unlink()
        self.git('checkout', '-q', '-b', 'topic')
        with self.assertRaisesRegex(release.ReleaseError, 'Release from main'):
            local.assert_source(self.plan)

    def test_build_snapshot_is_committed_source_and_does_not_create_the_real_tag(self):
        (self.root / 'RELEASE_NOTES.md').write_text('later uncommitted edit')
        source = local.snapshot(self.plan, self.hub.repository)
        self.assertIn('Fixture notes', (source / 'RELEASE_NOTES.md').read_text())
        self.assertEqual(local.git(source, 'rev-parse', 'HEAD'), self.source)
        self.assertEqual(local.git(source, 'rev-parse', 'refs/tags/v0.2.0'), self.source)
        self.assertIsNone(local.git(self.root, 'rev-parse', '--verify', 'refs/tags/v0.2.0', optional=True))
        self.assertEqual(local.git(source, 'remote', 'get-url', 'origin'), 'https://github.com/xiaolai/uniplayer.git')

    def test_changed_candidate_snapshot_is_not_reset_or_overwritten(self):
        source = local.snapshot(self.plan, self.hub.repository)
        (source / 'RELEASE_NOTES.md').write_text('retain evidence')
        with self.assertRaisesRegex(release.ReleaseError, 'snapshot changed'):
            local.snapshot(self.plan, self.hub.repository)
        self.assertEqual((source / 'RELEASE_NOTES.md').read_text(), 'retain evidence')

    def test_one_local_release_owns_the_repository_lock(self):
        with local.release_lock(self.root):
            with self.assertRaisesRegex(release.ReleaseError, 'Another local release'):
                with local.release_lock(self.root):
                    self.fail('Concurrent release admitted')
        with local.release_lock(self.root):
            pass

    def test_origin_with_embedded_credentials_or_another_repo_is_refused(self):
        local.validate_origin(self.plan, self.hub.repository)
        self.git('remote', 'set-url', 'origin', 'https://fixture-token@github.com/xiaolai/uniplayer.git')
        with self.assertRaisesRegex(release.ReleaseError, 'without embedded credentials'):
            local.validate_origin(self.plan, self.hub.repository)

    def test_remote_tag_change_blocks_a_new_release(self):
        self.assertFalse(local.remote_state(self.plan, self.hub))
        original = self.hub.api
        self.hub.api = lambda path, **kw: {'object': {'type': 'tag', 'sha': 'b' * 40}} if '/git/ref/tags/' in path else original(path, **kw)
        self.hub.source = 'c' * 40
        with self.assertRaisesRegex(release.ReleaseError, 'Remote version tag'):
            local.remote_state(self.plan, self.hub)

    def test_new_version_uses_missing_git_ref_not_the_422_commit_endpoint(self):
        paths = []
        original = self.hub.api
        def record(path, **kwargs):
            paths.append(path)
            return original(path, **kwargs)
        self.hub.api = record
        self.assertFalse(local.remote_state(self.plan, self.hub))
        self.assertTrue(any('/git/ref/tags/v0.2.0' in path for path in paths))
        self.assertFalse(any('/commits/' in path for path in paths))

    def test_dependency_cache_is_copied_and_hashed_without_downloading(self):
        source, cache = Path(self.temporary.name) / 'source', self.root
        (source / 'other').mkdir(parents=True)
        file = cache / 'deps/lib/fixture.dylib'
        file.parent.mkdir(parents=True)
        file.write_bytes(b'synthetic library')
        (source / 'other/dylibs-universal.lock').write_text(release.digest(file) + '  fixture.dylib\n')
        with patch.object(local, 'stage_runner'):
            local.dependencies(source, cache, lambda *args: self.fail('Unexpected download'))
        copied = source / 'deps/lib/fixture.dylib'
        self.assertEqual(copied.read_bytes(), file.read_bytes())
        self.assertFalse(copied.is_symlink())
        with self.assertRaises(release.ReleaseError):
            local.dependency_paths('a' * 64 + '  ../escape')

    def test_bad_dependency_download_cannot_continue_to_build(self):
        source = Path(self.temporary.name) / 'source'
        (source / 'other').mkdir(parents=True)
        (source / 'other/dylibs-universal.lock').write_text('a' * 64 + '  missing.dylib\n')
        calls = []
        with self.assertRaisesRegex(release.ReleaseError, 'do not match'):
            local.dependencies(source, self.root, lambda *args: calls.append(args))
        self.assertEqual(len(calls), 1)

    def test_build_subprocesses_do_not_receive_exported_credentials(self):
        with patch.dict(os.environ, {'APPLE_ID': 'fixture@example.invalid', 'APP_SPECIFIC_PASSWORD': 'fake-password',
                                     'GH_TOKEN': 'fake-token', 'HOMEBREW_TAP_TOKEN': 'fake-tap-token'}):
            env = local.build_environment()
        self.assertFalse(any(name in env for name in ['APPLE_ID', 'APP_SPECIFIC_PASSWORD', 'GH_TOKEN', 'HOMEBREW_TAP_TOKEN']))

    def test_notary_bootstrap_is_profile_only_and_hides_helper_output(self):
        loader = self.root / 'credential-loader.sh'
        loader.touch()
        with patch.object(local, 'profile_ready', side_effect=[False, True]), \
                patch.object(local.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='fake secret')) as run, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            local.ensure_profile(self.plan, 'fixture-profile', Path('/fixture/keychain'), loader)
        self.assertEqual(output.getvalue(), '')
        self.assertEqual(run.call_args.args[0][-3:], ['--profile', 'fixture-profile', '--profile-only'])
        self.assertTrue(run.call_args.kwargs['capture_output'])

    def test_source_push_is_exact_and_never_force_pushes(self):
        calls = []
        def git(root, *args, **kwargs):
            calls.append(args)
            return None if args[0] == 'rev-parse' else ''
        self.hub.source = self.source
        with patch.object(local, 'assert_source'), patch.object(local, 'remote_state'), patch.object(local, 'git', side_effect=git):
            local.push_source(self.plan, self.hub)
        pushes = [args for args in calls if args[0] == 'push']
        self.assertEqual(pushes, [('push', 'origin', self.source + ':refs/heads/main'),
                                 ('push', 'origin', 'refs/tags/v0.2.0:refs/tags/v0.2.0')])
        self.assertFalse(any('--force' in arg or '--no-verify' in arg for args in calls for arg in args))

    def test_check_mode_does_not_build_bootstrap_push_or_publish(self):
        def probe(args):
            if args[0] == 'security':
                return '1) ABC "Developer ID Application: Fixture (FAKETEAM00)"'
            if '--show-sdk-version' in args:
                return '27.0'
            if args[0] == 'xcodebuild':
                return 'Xcode 27.1\nBuild version fixture'
            return ''
        with patch.object(local, 'plan_for', return_value=self.plan), patch.object(local, 'GitHub', return_value=self.hub), \
                patch.object(local, 'probe', side_effect=probe), patch.object(local.shutil, 'which', return_value='/fixture/tool'), \
                patch.object(local, 'build_candidate') as build, patch.object(local, 'ensure_profile') as profile, \
                patch.object(local, 'push_source') as push, patch.object(sys, 'argv', ['release_local.py', '--check']), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(local.main(), 0)
        self.assertTrue(json.loads(output.getvalue())['ready'])
        build.assert_not_called()
        profile.assert_not_called()
        push.assert_not_called()
        self.assertEqual(self.hub.events, [])

    def test_package_failure_cannot_push_or_publish(self):
        with patch.object(local, 'plan_for', return_value=self.plan), patch.object(local, 'GitHub', return_value=self.hub), \
                patch.object(local, 'release_lock', return_value=contextlib.nullcontext()), \
                patch.object(local, 'ensure_profile'), patch.object(local, 'readiness', return_value={'ready': True}), \
                patch.object(local, 'build_candidate', side_effect=release.ReleaseError('package failed')), \
                patch.object(local, 'push_source') as push, patch.object(sys, 'argv', ['release_local.py']):
            with self.assertRaisesRegex(release.ReleaseError, 'package failed'):
                local.main()
        push.assert_not_called()
        self.assertEqual(self.hub.events, [])

    def test_resume_uses_the_published_tag_config_and_never_rebuilds(self):
        folder = Path(self.temporary.name) / 'published'
        folder.mkdir()
        bundle = fixtures.fixture(folder)
        self.hub.source = fixtures.SOURCE
        draft = self.hub.create_draft(bundle, 'notes')
        self.hub.upload(bundle, draft)
        self.hub.publish(draft)
        self.hub.events = []
        config = base64.b64encode(b'MARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 15\n').decode()
        self.hub.api = lambda *args, **kwargs: {'content': config}
        target = Path(self.temporary.name) / 'recovery'
        target.mkdir()
        with patch.object(local, 'build_candidate') as build, patch.object(local, 'push_source') as push:
            local.resume_published(self.hub, 'v0.2.0', target)
        build.assert_not_called()
        push.assert_not_called()
        self.assertNotIn('upload', self.hub.events)
        self.assertEqual(release.cask_values(self.hub.cask), ('0.2.0', bundle.sha256))


if __name__ == '__main__':
    unittest.main()
