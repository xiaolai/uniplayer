import copy
import hashlib
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
import github_release as release

SOURCE = 'a' * 40
OLD_HASH = 'b' * 64
CASK = '''cask "uniplayer" do
  version "0.1.7"
  sha256 "''' + OLD_HASH + '''"
  url "https://github.com/xiaolai/uniplayer/releases/download/v#{version}/UniPlayer-#{version}-universal.dmg"
  name "UniPlayer"
  depends_on macos: :golden_gate
  app "UniPlayer.app"
end
'''


def fixture(directory):
    directory = Path(directory)
    name = 'UniPlayer-0.2.0-universal.dmg'
    (directory / name).write_bytes(b'synthetic signed DMG fixture, not an application')
    sha = release.digest(directory / name)
    (directory / 'SHA256SUMS.txt').write_text(f'{sha}  {name}\n')
    manifest = {'schema': 1, 'tag': 'v0.2.0', 'version': '0.2.0', 'build': '15', 'source_sha': SOURCE,
                'assets': {n: {'sha256': release.digest(directory / n), 'size': (directory / n).stat().st_size}
                           for n in [name, 'SHA256SUMS.txt']}}
    (directory / release.MANIFEST).write_text(json.dumps(manifest))
    return release.Bundle.load(directory, 'v0.2.0', SOURCE, '0.2.0', '15')


class FakeHub(release.GitHub):
    def __init__(self):
        self.repository = 'xiaolai/uniplayer'
        self.inventory = [{'id': 1, 'tag_name': 'v0.1.7', 'draft': False, 'prerelease': False,
                           'published_at': '2026-10-23T01:00:00Z', 'assets': []}]
        self.latest_id = 1
        self.cask = CASK
        self.cask_revision = 1
        self.events = []
        self.fail_tap = False
        self.conflict_tap = False
        self.bad_readback = False
        self.source = SOURCE
        self.assets = {}

    def release(self, tag):
        return copy.deepcopy(next((r for r in self.inventory if r['tag_name'] == tag), None))

    def latest(self):
        return copy.deepcopy(next((r for r in self.inventory if r['id'] == self.latest_id), None))

    def tag_commit(self, tag):
        return self.source

    def releases(self):
        return copy.deepcopy(self.inventory)

    def tap_file(self):
        return str(self.cask_revision), self.cask

    def put_cask(self, sha, content, version):
        self.events.append('tap-write')
        if self.fail_tap:
            raise release.APIError(403)
        if self.conflict_tap:
            self.conflict_tap = False
            self.cask_revision += 1
            self.cask += '# independent tap edit\n'
            raise release.APIError(409)
        if not self.bad_readback:
            self.cask = content
            self.cask_revision += 1

    def create_draft(self, bundle, notes):
        self.events.append('draft')
        value = {'id': 2, 'tag_name': bundle.tag, 'draft': True, 'prerelease': False,
                 'published_at': None, 'assets': [], 'html_url': 'https://github.com/xiaolai/uniplayer/releases/tag/' + bundle.tag}
        self.inventory.append(value)
        return copy.deepcopy(value)

    def upload(self, bundle, value):
        self.events.append('upload')
        current = next(r for r in self.inventory if r['id'] == value['id'])
        current['assets'] = []
        for name in bundle.names:
            data = (bundle.directory / name).read_bytes()
            self.assets[name] = data
            current['assets'].append({'name': name, 'state': 'uploaded', 'size': len(data),
                                      'digest': 'sha256:' + hashlib.sha256(data).hexdigest()})

    def verify_assets(self, bundle, value):
        self.events.append('verify')
        super().verify_assets(bundle, value)

    def download(self, tag, directory, names):
        for name in names:
            (Path(directory) / name).write_bytes(self.assets[name])

    def publish(self, value):
        self.events.append('publish')
        current = next(r for r in self.inventory if r['id'] == value['id'])
        current.update(draft=False, published_at='2026-10-24T01:00:00Z')
        self.latest_id = value['id']
        return copy.deepcopy(current)

    def delete_release(self, value):
        self.events.append('delete-' + str(value))
        self.inventory = [r for r in self.inventory if r['id'] != value]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = fixture(self.temporary.name)
        self.hub = FakeHub()

    def test_order_is_verify_publish_tap_then_retention(self):
        result = release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(result['tag_name'], 'v0.2.0')
        self.assertEqual(self.hub.events, ['draft', 'upload', 'verify', 'publish', 'verify', 'tap-write', 'delete-1'])
        self.assertEqual([r['tag_name'] for r in self.hub.inventory], ['v0.2.0'])
        self.assertEqual(release.cask_values(self.hub.cask), ('0.2.0', self.bundle.sha256))

    def test_tap_failure_keeps_old_release_and_resume_never_reuploads(self):
        self.hub.fail_tap = True
        with self.assertRaises(release.APIError):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(len(self.hub.inventory), 2)
        self.assertEqual(release.cask_values(self.hub.cask)[0], '0.1.7')
        self.assertFalse(any(e.startswith('delete-') for e in self.hub.events))
        self.hub.fail_tap = False
        self.hub.events = []
        release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertNotIn('upload', self.hub.events)
        self.assertNotIn('publish', self.hub.events)
        self.assertEqual(self.hub.events, ['verify', 'tap-write', 'delete-1'])

    def test_failed_upload_keeps_the_previous_release_and_tap(self):
        def fail(bundle, draft):
            raise release.APIError(502)
        self.hub.upload = fail
        with self.assertRaises(release.APIError):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(self.hub.latest()['tag_name'], 'v0.1.7')
        self.assertEqual(self.hub.cask, CASK)
        self.assertEqual(self.hub.events, ['draft'])

    def test_tap_readback_failure_blocks_every_delete(self):
        self.hub.bad_readback = True
        with self.assertRaisesRegex(release.ReleaseError, 'read-back'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(len(self.hub.inventory), 2)

    def test_changed_tap_during_retention_blocks_deletion(self):
        inventory = self.hub.releases
        def concurrent_change():
            self.hub.cask = CASK
            return inventory()
        self.hub.releases = concurrent_change
        with self.assertRaisesRegex(release.ReleaseError, 'Homebrew changed'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertFalse(any(e.startswith('delete-') for e in self.hub.events))

    def test_readback_cannot_change_the_download_repository(self):
        write = self.hub.put_cask
        def concurrent_change(sha, content, version):
            write(sha, content, version)
            self.hub.cask = self.hub.cask.replace('xiaolai/uniplayer', 'example/other')
        self.hub.put_cask = concurrent_change
        with self.assertRaisesRegex(release.ReleaseError, 'URL'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertFalse(any(e.startswith('delete-') for e in self.hub.events))

    def test_contents_conflict_reloads_and_preserves_an_unrelated_tap_edit(self):
        self.hub.conflict_tap = True
        release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertIn('# independent tap edit', self.hub.cask)
        self.assertEqual(self.hub.events.count('tap-write'), 2)

    def test_newer_release_or_cask_prevents_publication(self):
        self.hub.inventory[0]['tag_name'] = 'v0.3.0'
        with self.assertRaisesRegex(release.ReleaseError, 'newer'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(self.hub.events, [])
        self.hub.inventory[0]['tag_name'] = 'v0.1.7'
        self.hub.cask = CASK.replace('0.1.7', '0.3.0')
        with self.assertRaisesRegex(release.ReleaseError, 'downgrade'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(self.hub.events, [])

    def test_moved_tag_cannot_publish_or_prune(self):
        self.hub.source = 'c' * 40
        with self.assertRaisesRegex(release.ReleaseError, 'tag moved'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(self.hub.events, [])

    def test_published_assets_are_immutable_and_mismatch_cannot_update_tap(self):
        draft = self.hub.create_draft(self.bundle, 'Notes')
        self.hub.upload(self.bundle, draft)
        self.hub.publish(draft)
        self.hub.inventory[-1]['assets'][0]['digest'] = 'sha256:' + 'f' * 64
        self.hub.events = []
        with self.assertRaisesRegex(release.ReleaseError, 'checksum differs'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual(self.hub.events, ['verify'])
        self.assertEqual(len(self.hub.inventory), 2)

    def test_retention_preserves_drafts_and_never_deletes_a_newer_prerelease(self):
        self.hub.inventory.append({'id': 3, 'tag_name': 'future-draft', 'draft': True})
        release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertEqual({r['id'] for r in self.hub.inventory}, {2, 3})
        self.hub.inventory.append({'id': 4, 'tag_name': 'v0.3.0-beta', 'draft': False,
                                  'published_at': '2026-10-23T02:00:00Z', 'prerelease': True})
        self.hub.events = []
        with self.assertRaisesRegex(release.ReleaseError, 'newer version'):
            release.publish_bundle(self.hub, self.bundle, 'Notes')
        self.assertFalse(any(e.startswith('delete-') for e in self.hub.events))

    def test_missing_server_digest_downloads_and_hashes_the_actual_asset(self):
        draft = self.hub.create_draft(self.bundle, 'Notes')
        self.hub.upload(self.bundle, draft)
        for asset in self.hub.inventory[-1]['assets']:
            asset.pop('digest')
        self.hub.verify_assets(self.bundle, self.hub.release(self.bundle.tag))
        self.hub.assets[self.bundle.dmg] = b'corrupt'
        with self.assertRaisesRegex(release.ReleaseError, 'checksum differs'):
            self.hub.verify_assets(self.bundle, self.hub.release(self.bundle.tag))

    def test_checksum_and_source_tampering_are_rejected(self):
        root = self.bundle.directory
        (root / self.bundle.dmg).write_bytes(b'corrupt')
        with self.assertRaisesRegex(release.ReleaseError, 'mismatch'):
            release.Bundle.load(root, 'v0.2.0', SOURCE, '0.2.0', '15')
        with self.assertRaisesRegex(release.ReleaseError, 'checkout'):
            release.Bundle.load(root, 'v0.2.0', 'c' * 40, '0.2.0', '15')

    def test_symlinked_asset_is_rejected(self):
        path = self.bundle.directory / self.bundle.dmg
        target = self.bundle.directory / 'other-fixture'
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaisesRegex(release.ReleaseError, 'unsafe release asset'):
            release.Bundle.load(self.bundle.directory, 'v0.2.0', SOURCE, '0.2.0', '15')

    def test_production_upload_refuses_a_published_release(self):
        draft = self.hub.create_draft(self.bundle, 'Notes')
        published = self.hub.publish(draft)
        with self.assertRaisesRegex(release.ReleaseError, 'no longer our draft'):
            release.GitHub.upload(self.hub, self.bundle, published)

    def test_tag_input_and_cask_structure_are_strict(self):
        for tag in ['v0.2.0;echo secret', 'v0.2.0-beta', 'v00.2.0', 'main', 'v0.2.0\n']:
            with self.assertRaises(release.ReleaseError):
                release.version_tuple(tag)
        with self.assertRaisesRegex(release.ReleaseError, 'URL'):
            release.updated_cask(CASK.replace('xiaolai/uniplayer', 'example/other'), '0.2.0', self.bundle.sha256, self.hub.repository)
        with self.assertRaisesRegex(release.ReleaseError, 'exactly one'):
            release.cask_values(CASK + '  version "0.1.6"\n')

    def test_stable_release_notes_do_not_adopt_prerelease_notes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            notes = root / 'RELEASE_NOTES.md'
            notes.write_text('## 0.2.0-beta\n\nBeta only\n')
            with self.assertRaises(release.ReleaseError):
                release.notes_for('0.2.0', root)
            notes.write_text(notes.read_text() + '\n## 0.2.0 (build 15, unreleased)\n\nStable notes\n')
            self.assertEqual(release.notes_for('0.2.0', root), 'Stable notes')

    def test_resume_cannot_replace_a_cask_checksum_for_the_same_version(self):
        with self.assertRaisesRegex(release.ReleaseError, 'different checksum'):
            release.updated_cask(CASK.replace('0.1.7', '0.2.0'), '0.2.0', self.bundle.sha256, self.hub.repository)

    def test_releases_inventory_is_paginated_before_retention(self):
        hub = release.GitHub('xiaolai/uniplayer', 'fake-token', tap_token='fake-tap-token')
        pages = []
        def api(path):
            pages.append(path)
            return [{'id': n} for n in range(100)] if path.endswith('&page=1') else [{'id': 100}]
        hub.api = api
        self.assertEqual(len(hub.releases()), 101)
        self.assertEqual(len(pages), 2)

    def test_cli_tokens_are_environment_only_and_other_secrets_are_scrubbed(self):
        hub = release.GitHub('xiaolai/uniplayer', 'fake-token', tap_token='fake-tap-token')
        with patch.dict(os.environ, {'APP_SPECIFIC_PASSWORD': 'fake-apple-secret'}), \
                patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='{}')) as run:
            hub.api('repos/xiaolai/homebrew-tap', tap=True)
        args, kwargs = run.call_args
        self.assertNotIn('fake-tap-token', ' '.join(args[0]))
        self.assertEqual(kwargs['env']['GH_TOKEN'], 'fake-tap-token')
        self.assertNotIn('APP_SPECIFIC_PASSWORD', kwargs['env'])
        self.assertNotIn('shell', kwargs)

    def test_local_auth_uses_saved_gh_login_without_exporting_a_token(self):
        hub = release.GitHub('xiaolai/uniplayer', cli_auth=True)
        with patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='{}')) as run:
            hub.api('repos/xiaolai/homebrew-tap', tap=True)
        self.assertNotIn('GH_TOKEN', run.call_args.kwargs['env'])
        self.assertNotIn('GITHUB_TOKEN', run.call_args.kwargs['env'])
        self.assertEqual(run.call_args.args[0][:2], ['gh', 'api'])

    def test_tag_checkout_must_be_clean_and_on_main(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args, input=None):
                return subprocess.check_output(['git', '-c', 'user.name=Fixture', '-c',
                                                'user.email=fixture@example.invalid', *args],
                                               cwd=root, text=True, input=input).strip()
            git('init', '-q')
            (root / 'Configs').mkdir()
            (root / 'Configs/Deployment.xcconfig').write_text('MARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 15\n')
            (root / 'RELEASE_NOTES.md').write_text('# Notes\n\n## 0.2.0 (unreleased)\n\nFixture notes\n')
            git('add', '.')
            tree = git('write-tree')
            source = git('commit-tree', tree, '-m', 'Synthetic test fixture')
            git('update-ref', 'refs/heads/main', source)
            git('symbolic-ref', 'HEAD', 'refs/heads/main')
            git('update-ref', 'refs/remotes/origin/main', source)
            git('tag', 'v0.2.0', source)
            self.assertEqual(release.checkout('v0.2.0', root), ('0.2.0', '15', source))
            (root / 'RELEASE_NOTES.md').write_text('changed')
            with self.assertRaisesRegex(release.ReleaseError, 'modified tracked'):
                release.checkout('v0.2.0', root)
            git('checkout', '--', 'RELEASE_NOTES.md')
            unrelated = git('commit-tree', tree, '-p', source, '-m', 'Synthetic unmerged fixture')
            git('update-ref', 'refs/heads/main', unrelated)
            git('tag', '-f', 'v0.2.0', unrelated)
            with self.assertRaisesRegex(release.ReleaseError, 'not on origin/main'):
                release.checkout('v0.2.0', root)

    def test_manifest_command_requires_both_notarization_receipts(self):
        directory = self.bundle.directory
        (directory / release.MANIFEST).unlink()
        for kind in ['app', 'dmg']:
            (directory / f'{kind}-notary.json').write_text(json.dumps({'status': 'Accepted'}))
            (directory / f'{kind}-notary.issues.json').write_text(json.dumps({'issues': None}))
        argv = ['github_release.py', 'manifest', '--tag', 'v0.2.0', '--directory', str(directory)]
        with patch.object(release, 'checkout', return_value=('0.2.0', '15', SOURCE)), patch.object(sys, 'argv', argv):
            release.main()
        release.Bundle.load(directory, 'v0.2.0', SOURCE, '0.2.0', '15')
        (directory / release.MANIFEST).unlink()
        (directory / 'dmg-notary.json').write_text(json.dumps({'status': 'Rejected'}))
        with patch.object(release, 'checkout', return_value=('0.2.0', '15', SOURCE)), patch.object(sys, 'argv', argv):
            with self.assertRaisesRegex(release.ReleaseError, 'Notarization evidence'):
                release.main()
        self.assertFalse((directory / release.MANIFEST).exists())


if __name__ == '__main__':
    unittest.main()
