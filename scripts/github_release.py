#!/usr/bin/env python3
"""Publish a verified UniPlayer release, update its cask, then retain one release.

Network mutations occur only in the publish command. Never reads workspace .env.
"""
import argparse
import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'release-manifest.json'


class ReleaseError(RuntimeError):
    pass


class APIError(ReleaseError):
    def __init__(self, status):
        self.status = status
        super().__init__(f'GitHub API request failed (HTTP {status or "unknown"}); no automatic retry of uncertain writes')


def version_tuple(tag):
    match = re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag)
    if not match:
        raise ReleaseError('Use an existing stable tag in the form vMAJOR.MINOR.PATCH')
    return tuple(map(int, match.groups()))


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def configuration(root=ROOT):
    values = dict(re.findall(r'^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$',
                            (root / 'Configs/Deployment.xcconfig').read_text(), re.M))
    version_tuple('v' + values['MARKETING_VERSION'])
    build = values['CURRENT_PROJECT_VERSION']
    if not re.fullmatch(r'[1-9]\d*', build):
        raise ReleaseError('Invalid CURRENT_PROJECT_VERSION')
    return values['MARKETING_VERSION'], build


def cask_values(text):
    if not re.search(r'^cask "uniplayer" do$', text, re.M):
        raise ReleaseError('Refusing to modify a different cask')
    versions = re.findall(r'^  version "([^"]+)"$', text, re.M)
    hashes = re.findall(r'^  sha256 "([0-9a-f]{64})"$', text, re.M)
    if len(versions) != 1 or len(hashes) != 1:
        raise ReleaseError('Expected exactly one literal cask version and SHA-256')
    version_tuple('v' + versions[0])
    return versions[0], hashes[0]


def updated_cask(text, version, sha256, repository):
    previous, old_hash = cask_values(text)
    if version_tuple('v' + previous) > version_tuple('v' + version):
        raise ReleaseError('Refusing to downgrade the Homebrew cask')
    expected_url = f'https://github.com/{repository}/releases/download/v#{{version}}/UniPlayer-#{{version}}-universal.dmg'
    if f'url "{expected_url}"' not in text:
        raise ReleaseError('Cask download URL does not match this release repository')
    if previous == version:
        if old_hash != sha256:
            raise ReleaseError('This cask version already has a different checksum; do not replace a published build')
        return text
    text = re.sub(r'^  version "[^"]+"$', f'  version "{version}"', text, flags=re.M)
    return re.sub(r'^  sha256 "[0-9a-f]{64}"$', f'  sha256 "{sha256}"', text, flags=re.M)


def assert_not_older(tag, latest):
    requested = version_tuple(tag)
    if latest and version_tuple(latest['tag_name']) > requested:
        raise ReleaseError('A newer stable release already exists; refusing downgrade or retention')


@dataclass
class Bundle:
    directory: Path
    tag: str
    source: str
    version: str
    build: str
    dmg: str
    sha256: str

    @property
    def names(self):
        return [self.dmg, 'SHA256SUMS.txt', MANIFEST]

    @classmethod
    def load(cls, directory, tag, source, version, build):
        version_tuple(tag)
        if tag != 'v' + version or not re.fullmatch(r'[0-9a-f]{40}', source):
            raise ReleaseError('Tag or source revision mismatch')
        directory = Path(directory)
        manifest = json.loads((directory / MANIFEST).read_text())
        expected = {'schema': 1, 'tag': tag, 'source_sha': source, 'version': version, 'build': build}
        if any(manifest.get(k) != v for k, v in expected.items()):
            raise ReleaseError('Release manifest does not match this checkout')
        dmg = f'UniPlayer-{version}-universal.dmg'
        if set(manifest.get('assets', {})) != {dmg, 'SHA256SUMS.txt'}:
            raise ReleaseError('Unexpected release manifest assets')
        for name in [dmg, 'SHA256SUMS.txt', MANIFEST]:
            path = directory / name
            if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
                raise ReleaseError('Missing or unsafe release asset: ' + name)
            if name != MANIFEST:
                record = manifest['assets'][name]
                if record.get('sha256') != digest(path) or record.get('size') != path.stat().st_size:
                    raise ReleaseError('Release asset size/checksum mismatch: ' + name)
        sha = digest(directory / dmg)
        if (directory / 'SHA256SUMS.txt').read_text() != f'{sha}  {dmg}\n':
            raise ReleaseError('SHA256SUMS.txt does not identify exactly this DMG')
        return cls(directory, tag, source, version, build, dmg, sha)


class GitHub:
    """CLI transport: token only in the child environment; no shell interpolation."""
    def __init__(self, repository, token=None, tap_repository='xiaolai/homebrew-tap', tap_token=None, cli_auth=False):
        for value in [repository, tap_repository]:
            if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value):
                raise ReleaseError('Invalid repository name')
        if not cli_auth and (not token or not tap_token):
            raise ReleaseError('GH_TOKEN and HOMEBREW_TAP_TOKEN are required')
        self.repository, self.token = repository, token
        self.tap_repository, self.tap_token = tap_repository, tap_token

    def command(self, args, token=None, data=None):
        env = {key: os.environ[key] for key in ['PATH', 'HOME', 'TMPDIR', 'LANG', 'GH_CONFIG_DIR', 'XDG_CONFIG_HOME'] if key in os.environ}
        env.update(GH_HOST='github.com', GH_PROMPT_DISABLED='1')
        if token or self.token:
            env['GH_TOKEN'] = token or self.token
        result = subprocess.run(['gh', *args], input=data, text=True, capture_output=True, env=env)
        if result.returncode:
            match = re.search(r'HTTP (\d+)', result.stderr)
            raise APIError(int(match[1]) if match else None)
        return result.stdout

    def api(self, path, method='GET', body=None, tap=False, missing=False):
        args = ['api', '--method', method, '-H', 'Accept: application/vnd.github+json',
                '-H', 'X-GitHub-Api-Version: 2026-03-10', '-H', 'Cache-Control: no-cache', path]
        if body is not None:
            args += ['--input', '-']
        try:
            raw = self.command(args, self.tap_token if tap else None,
                               json.dumps(body) if body is not None else None)
        except APIError as error:
            if missing and error.status == 404:
                return None
            raise
        return json.loads(raw) if raw.strip() else None

    def release(self, tag):
        return self.api(f'repos/{self.repository}/releases/tags/{quote(tag, safe="")}', missing=True)

    def latest(self):
        return self.api(f'repos/{self.repository}/releases/latest', missing=True)

    def tag_commit(self, tag):
        return self.api(f'repos/{self.repository}/commits/{quote(tag, safe="")}')['sha']

    def releases(self):
        result = []
        for page in range(1, 101):
            values = self.api(f'repos/{self.repository}/releases?per_page=100&page={page}')
            result.extend(values)
            if len(values) < 100:
                return result
        raise ReleaseError('Release inventory exceeds the retention safety bound')

    def tap_file(self):
        value = self.api(f'repos/{self.tap_repository}/contents/Casks/uniplayer.rb', tap=True)
        return value['sha'], base64.b64decode(value['content'], validate=False).decode()

    def put_cask(self, sha, content, version):
        self.api(f'repos/{self.tap_repository}/contents/Casks/uniplayer.rb', 'PUT',
                 {'message': f'Update UniPlayer to {version}', 'sha': sha,
                  'content': base64.b64encode(content.encode()).decode()}, tap=True)

    def create_draft(self, bundle, notes):
        return self.api(f'repos/{self.repository}/releases', 'POST',
                        {'tag_name': bundle.tag, 'target_commitish': bundle.source,
                         'name': f'UniPlayer {bundle.version}', 'body': notes,
                         'draft': True, 'prerelease': False, 'make_latest': 'false'})

    def upload(self, bundle, release):
        current = self.release(bundle.tag)
        if not current or current['id'] != release['id'] or not current['draft']:
            raise ReleaseError('Release is no longer our draft; refusing asset replacement')
        self.command(['release', 'upload', bundle.tag, *[str(bundle.directory / n) for n in bundle.names],
                      '--repo', self.repository, '--clobber'])

    def download(self, tag, directory, names):
        Path(directory).mkdir(parents=True, exist_ok=True)
        args = ['release', 'download', tag, '--repo', self.repository, '--dir', str(directory), '--clobber']
        for name in names:
            args += ['--pattern', name]
        self.command(args)

    def verify_assets(self, bundle, release):
        assets = {asset['name']: asset for asset in release.get('assets', [])}
        for name in bundle.names:
            asset = assets.get(name)
            if not asset or asset.get('state') != 'uploaded' or asset['size'] != (bundle.directory / name).stat().st_size:
                raise ReleaseError('Release asset missing, incomplete or size differs: ' + name)
            expected = digest(bundle.directory / name)
            remote_digest = asset.get('digest')
            if remote_digest:
                if remote_digest != 'sha256:' + expected:
                    raise ReleaseError('Published asset checksum differs: ' + name)
            else:
                with tempfile.TemporaryDirectory(prefix='uniplayer-verify-') as tmp:
                    self.download(bundle.tag, tmp, [name])
                    if digest(Path(tmp) / name) != expected:
                        raise ReleaseError('Downloaded asset checksum differs: ' + name)

    def publish(self, release):
        return self.api(f'repos/{self.repository}/releases/{release["id"]}', 'PATCH',
                        {'draft': False, 'prerelease': False, 'make_latest': 'true'})

    def delete_release(self, release_id):
        # Deliberately do not delete the associated Git tag.
        self.api(f'repos/{self.repository}/releases/{release_id}', 'DELETE')


def update_tap(client, bundle):
    for attempt in range(3):
        sha, original = client.tap_file()
        changed = updated_cask(original, bundle.version, bundle.sha256, client.repository)
        if changed != original:
            try:
                client.put_cask(sha, changed, bundle.version)
            except APIError as error:
                if error.status == 409 and attempt < 2:
                    continue  # A definite conflict, not an uncertain write.
                raise
        _, actual = client.tap_file()
        if cask_values(actual) != (bundle.version, bundle.sha256):
            raise ReleaseError('Tap read-back differs; older releases retained')
        updated_cask(actual, bundle.version, bundle.sha256, client.repository)
        return
    raise ReleaseError('Tap kept changing; older releases retained')


def retain_latest(client, keep, bundle):
    latest = client.latest()
    if not latest or latest['id'] != keep['id'] or keep['draft'] or keep['prerelease']:
        raise ReleaseError('Current release is not the latest stable release; retention refused')
    inventory = client.releases()  # Snapshot before deleting; no pagination skipping.
    for value in inventory:
        if value['id'] == keep['id'] or value['draft']:
            continue
        if not value.get('published_at') or value['published_at'] > keep['published_at']:
            raise ReleaseError('A newer release appeared; retention refused')
        match = re.match(r'^v(\d+)\.(\d+)\.(\d+)', value['tag_name'])
        if match and tuple(map(int, match.groups())) > version_tuple(keep['tag_name']):
            raise ReleaseError('A newer version exists; retention refused')
    for value in inventory:
        if value['id'] == keep['id'] or value['draft']:
            continue
        latest = client.latest()
        if not latest or latest['id'] != keep['id']:
            raise ReleaseError('Latest release changed during retention')
        _, cask = client.tap_file()
        if cask_values(cask) != (bundle.version, bundle.sha256):
            raise ReleaseError('Homebrew changed during retention; older releases retained')
        updated_cask(cask, bundle.version, bundle.sha256, client.repository)
        client.delete_release(value['id'])


def publish_bundle(client, bundle, notes):
    assert_not_older(bundle.tag, client.latest())
    if client.tag_commit(bundle.tag) != bundle.source:
        raise ReleaseError('Remote tag moved; publication refused')
    _, cask = client.tap_file()
    updated_cask(cask, bundle.version, bundle.sha256, client.repository)  # Preflight before draft mutation.
    release = client.release(bundle.tag)
    if not release:
        release = client.create_draft(bundle, notes)
    if release['prerelease']:
        raise ReleaseError('Stable tag is already a prerelease; resolve it explicitly')
    if release['draft']:
        client.upload(bundle, release)
        release = client.release(bundle.tag)
        client.verify_assets(bundle, release)
        release = client.publish(release)
    # Published releases are never overwritten on retry.
    client.verify_assets(bundle, release)
    latest = client.latest()
    if not latest or latest['id'] != release['id']:
        raise ReleaseError('Published release is not latest; tap and retention untouched')
    update_tap(client, bundle)
    retain_latest(client, release, bundle)
    return release


def notes_for(version, root=ROOT):
    text = (root / 'RELEASE_NOTES.md').read_text()
    match = re.search(r'^## ' + re.escape(version) + r'(?:[ \t]+\([^\n]*\))?[ \t]*\n(.*?)(?=^## |\Z)',
                      text, re.M | re.S)
    if not match or not match[1].strip():
        raise ReleaseError('RELEASE_NOTES.md has no notes for this version')
    return match[1].strip()


def write_manifest(output, tag, source, version, build):
    output = Path(output)
    for kind in ['app', 'dmg']:
        report = json.loads((output / f'{kind}-notary.json').read_text())
        issues = json.loads((output / f'{kind}-notary.issues.json').read_text())
        if report.get('status') != 'Accepted' or issues.get('issues'):
            raise ReleaseError('Notarization evidence is not accepted and issue-free')
    names = [f'UniPlayer-{version}-universal.dmg', 'SHA256SUMS.txt']
    manifest = {'schema': 1, 'tag': tag, 'version': version, 'build': build, 'source_sha': source,
                'assets': {n: {'sha256': digest(output / n), 'size': (output / n).stat().st_size} for n in names}}
    (output / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
    return Bundle.load(output, tag, source, version, build)


def checkout(tag, root=ROOT):
    version, build = configuration(root)
    if tag != 'v' + version:
        raise ReleaseError('Release tag must match MARKETING_VERSION')
    version_tuple(tag)
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    if subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=root).returncode:
        raise ReleaseError('Release checkout has modified tracked files')
    if subprocess.run(['git', 'merge-base', '--is-ancestor', source, 'origin/main'], cwd=root).returncode:
        raise ReleaseError('Release commit is not on origin/main')
    tag_source = subprocess.check_output(['git', 'rev-parse', f'refs/tags/{tag}^{{commit}}'], cwd=root, text=True).strip()
    if tag_source != source:
        raise ReleaseError('Checkout is not the requested tag commit')
    notes_for(version, root)
    return version, build, source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'manifest', 'publish'])
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY', 'xiaolai/uniplayer'))
    parser.add_argument('--tap-repository', default='xiaolai/homebrew-tap')
    parser.add_argument('--directory', type=Path)
    args = parser.parse_args()
    if args.command in ['manifest', 'publish'] and args.directory is None:
        parser.error('--directory is required')
    version, build, source = checkout(args.tag)
    if args.command == 'manifest':
        write_manifest(args.directory, args.tag, source, version, build)
        return
    client = GitHub(args.repository, os.environ.get('GH_TOKEN'), args.tap_repository,
                    os.environ.get('HOMEBREW_TAP_TOKEN'), cli_auth=True)
    assert_not_older(args.tag, client.latest())
    if client.tag_commit(args.tag) != source:
        raise ReleaseError('Remote tag does not match checkout')
    if args.command == 'prepare':
        _, cask = client.tap_file()
        if version_tuple('v' + cask_values(cask)[0]) > version_tuple(args.tag):
            raise ReleaseError('Homebrew already points to a newer version')
        release = client.release(args.tag)
        if release and release['prerelease']:
            raise ReleaseError('Stable tag is already a prerelease')
        values = {'version': version, 'build': build, 'source_sha': source,
                  'published': str(bool(release and not release['draft'])).lower()}
        destination = os.environ.get('GITHUB_OUTPUT')
        if destination:
            with open(destination, 'a') as stream:
                for key, value in values.items():
                    stream.write(f'{key}={value}\n')
        print(json.dumps(values))
        return
    if args.directory is None:
        parser.error('--directory is required')
    if not (args.directory / MANIFEST).exists():
        release = client.release(args.tag)
        if not release or release['draft']:
            raise ReleaseError('No verified local bundle or published release to resume')
        client.download(args.tag, args.directory,
                        [f'UniPlayer-{version}-universal.dmg', 'SHA256SUMS.txt', MANIFEST])
    bundle = Bundle.load(args.directory, args.tag, source, version, build)
    release = publish_bundle(client, bundle, notes_for(version))
    print('Published and verified Homebrew; retained latest release:', release['html_url'])


if __name__ == '__main__':
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f'release: {error}', file=sys.stderr)
        sys.exit(1)
