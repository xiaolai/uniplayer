#!/usr/bin/env python3
"""Manually release UniPlayer using local Keychain identities and gh login.

Default invocation builds, pushes main/tag, publishes, updates Homebrew and
retains the newest published release. --check performs read-only readiness probes.
"""
import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from github_release import (APIError, Bundle, GitHub, MANIFEST, ROOT, ReleaseError,
                            assert_not_older, cask_values, configuration, digest,
                            notes_for, publish_bundle, updated_cask, version_tuple,
                            write_manifest)


def git(root, *args, optional=False):
    result = subprocess.run(['git', *args], cwd=root, capture_output=True, text=True)
    if result.returncode:
        if optional:
            return None
        raise ReleaseError(f'git {args[0]} failed; resolve repository/authentication state before retrying')
    return result.stdout.strip()


def build_environment():
    # Credentials never enter Xcode's environment or build logs.
    return {key: os.environ[key] for key in ['PATH', 'HOME', 'TMPDIR', 'DEVELOPER_DIR', 'LANG', 'LC_ALL']
            if key in os.environ}


def probe(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                env=build_environment(), timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


@dataclass(frozen=True)
class Plan:
    root: Path
    version: str
    build: str
    source: str
    tag: str
    output: Path


def plan_for(root=ROOT, output=None):
    root = Path(root).resolve()
    version, build = configuration(root)
    source = git(root, 'rev-parse', 'HEAD')
    artifacts = root.parent / 'release-artifacts' if root.name == 'main' else root / 'build/releases'
    return Plan(root, version, build, source, 'v' + version,
                Path(output).resolve() if output else artifacts / version / source[:12])


def assert_source(plan):
    if git(plan.root, 'branch', '--show-current') != 'main':
        raise ReleaseError('Release from main, after merging the intended features')
    if git(plan.root, 'status', '--porcelain', '--untracked-files=normal'):
        raise ReleaseError('Commit or move source changes before releasing; the script never stashes or commits them')
    if git(plan.root, 'rev-parse', 'HEAD') != plan.source:
        raise ReleaseError('Main changed during the release; the candidate is retained, nothing more is published')


def validate_origin(plan, repository):
    origin = git(plan.root, 'remote', 'get-url', 'origin')
    allowed = {f'git@github.com:{repository}.git', f'https://github.com/{repository}.git',
               f'https://github.com/{repository}', f'ssh://git@github.com/{repository}.git'}
    if origin not in allowed:
        raise ReleaseError('origin must point to the intended GitHub repository without embedded credentials')


def signing_identity():
    output = probe(['security', 'find-identity', '-v', '-p', 'codesigning'])
    matches = re.findall(r'"(Developer ID Application:[^"\n]+)"', output or '')
    selected = os.environ.get('UNIPLAYER_SIGN_IDENTITY')
    if selected and selected in matches:
        return selected
    if not selected and len(matches) == 1:
        return matches[0]
    raise ReleaseError('Unlock/provision one Developer ID Application identity, or select it with UNIPLAYER_SIGN_IDENTITY')


def profile_ready(profile, keychain):
    return probe(['xcrun', 'notarytool', 'history', '--keychain-profile', profile,
                  '--keychain', str(keychain)]) is not None


def remote_state(plan, client):
    assert_not_older(plan.tag, client.latest())
    for repository in [client.repository, client.tap_repository]:
        value = client.api('repos/' + repository)
        if not value.get('permissions', {}).get('push'):
            raise ReleaseError('The active gh account needs write access to both UniPlayer and its Homebrew tap')
    _, cask = client.tap_file()
    _, previous_hash = cask_values(cask)
    updated_cask(cask, plan.version, previous_hash, client.repository)
    remote_main = client.api(f'repos/{client.repository}/git/ref/heads/main')['object']['sha']
    if git(plan.root, 'merge-base', '--is-ancestor', remote_main, plan.source, optional=True) is None:
        raise ReleaseError('Remote main is not a known ancestor; synchronize/review local history before releasing')
    local_tag = git(plan.root, 'rev-parse', '--verify', '--quiet', f'refs/tags/{plan.tag}^{{commit}}', optional=True)
    if local_tag and local_tag != plan.source:
        raise ReleaseError('Local version tag points at another commit; bump the version instead of moving it')
    remote = client.api(f'repos/{client.repository}/commits/{plan.tag}', missing=True)
    if remote and remote['sha'] != plan.source:
        raise ReleaseError('Remote version tag points at another commit; use --resume TAG or bump the version')
    value = client.release(plan.tag)
    if value and value['prerelease']:
        raise ReleaseError('Stable tag is already a prerelease; resolve it explicitly')
    return bool(value and not value['draft'])


def readiness(plan, client, profile, keychain):
    issues = []
    for label, action in [('source', lambda: assert_source(plan)),
                          ('origin', lambda: validate_origin(plan, client.repository)),
                          ('notes', lambda: notes_for(plan.version, plan.root)),
                          ('GitHub/Homebrew', lambda: remote_state(plan, client))]:
        try:
            action()
        except (ReleaseError, OSError, ValueError, KeyError) as error:
            issues.append(f'{label}: {error}')
    for command in ['gh', 'git', 'xcodebuild', 'xcrun', 'security', 'node']:
        if not shutil.which(command):
            issues.append('Missing local tool: ' + command)
    sdk = probe(['xcrun', '--sdk', 'macosx', '--show-sdk-version'])
    xcode = probe(['xcodebuild', '-version'])
    if not sdk or int(sdk.split('.')[0]) < 27 or not xcode or not re.search(r'^Xcode (\d+)\.(\d+)', xcode):
        issues.append('Xcode 27.1+ and macOS SDK 27+ are required')
    elif tuple(map(int, re.search(r'^Xcode (\d+)\.(\d+)', xcode).groups())) < (27, 1):
        issues.append('Xcode 27.1+ is required')
    try:
        signing_identity()
    except ReleaseError as error:
        issues.append(str(error))
    if not profile_ready(profile, keychain):
        issues.append('Notarization profile unavailable; unlock the keychain or prepare the local profile')
    return {'version': plan.version, 'build': plan.build, 'tag': plan.tag, 'source_sha': plan.source,
            'ready': not issues, 'issues': issues}


@contextmanager
def release_lock(root):
    common = Path(git(root, 'rev-parse', '--git-common-dir'))
    common = common if common.is_absolute() else root / common
    fd = os.open(common / 'uniplayer-release.lock', os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError('Another local release is running for this repository') from None
        yield
    finally:
        os.close(fd)


def snapshot(plan, repository):
    target = plan.output / 'source'
    if not target.exists():
        plan.output.mkdir(parents=True, exist_ok=True)
        git(plan.root, 'clone', '--no-hardlinks', '--no-checkout', str(plan.root), str(target))
        git(target, 'checkout', '--detach', plan.source)
        git(target, 'remote', 'set-url', 'origin', f'https://github.com/{repository}.git')
    if (git(target, 'rev-parse', 'HEAD') != plan.source
            or git(target, 'status', '--porcelain', '--untracked-files=normal')):
        raise ReleaseError('Candidate source snapshot changed; choose a new --output directory')
    tag = git(target, 'rev-parse', '--verify', '--quiet', f'refs/tags/{plan.tag}^{{commit}}', optional=True)
    if tag and tag != plan.source:
        raise ReleaseError('Candidate snapshot has a conflicting tag')
    if not tag:
        git(target, 'tag', plan.tag, plan.source)  # Private build copy only; no source/remote tag yet.
    return target


def dependency_paths(line):
    if not line or line.startswith('#'):
        return None
    sha, name = line.split(None, 1)
    if not re.fullmatch(r'[0-9a-f]{64}', sha) or '..' in Path(name).parts or Path(name).is_absolute():
        raise ReleaseError('Invalid dependency lock entry')
    if name == 'executable/youtube-dl-github':
        path = 'deps/executable/youtube-dl'
    elif name.startswith('plugins/'):
        path = 'deps/' + name
    elif '/' not in name:
        path = 'deps/lib/' + name
    else:
        raise ReleaseError('Unknown dependency lock entry')
    return sha, path


def dependencies(source, cache, run):
    entries = [dependency_paths(line.strip()) for line in (source / 'other/dylibs-universal.lock').read_text().splitlines()]
    entries = [entry for entry in entries if entry]
    if not entries:
        raise ReleaseError('Empty dependency lock')
    for sha, name in entries:
        origin, target = cache / name, source / name
        if target.is_file() and digest(target) == sha:
            continue
        if origin.is_file() and digest(origin) == sha:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(origin, target)
    if any(not (source / name).is_file() or digest(source / name) != sha for sha, name in entries):
        run(['bash', str(source / 'other/download_libs.sh')], 'dependencies')
    if any(not (source / name).is_file() or digest(source / name) != sha for sha, name in entries):
        raise ReleaseError('Dependency files do not match the universal lock')


def stage_runner(source, output):
    def run(command, label):
        logs = output / 'logs'
        logs.mkdir(parents=True, exist_ok=True)
        log = logs / (label + '.log')
        print('Running:', label, flush=True)
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=source, env=build_environment(),
                                    stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise ReleaseError(f'{label} failed; inspect the local log: {log}')
    return run


def build_candidate(plan, client, profile, keychain):
    if (plan.output / MANIFEST).exists():
        bundle = Bundle.load(plan.output, plan.tag, plan.source, plan.version, plan.build)
        if probe(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature',
                  str(plan.output / bundle.dmg)]) is None:
            raise ReleaseError('Retained DMG no longer passes Gatekeeper')
        return bundle
    source = snapshot(plan, client.repository)
    run = stage_runner(source, plan.output)
    dependencies(source, plan.root, run)
    run([sys.executable, 'scripts/check-design-tokens.py', '--ledger'], 'tokens')
    run([sys.executable, '-m', 'unittest', 'scripts/test_check_design_tokens.py',
         'scripts/test_github_release.py', 'scripts/test_release_local.py'], 'script-tests')
    run([sys.executable, 'scripts/validate-browser-extensions.py'], 'browser-extensions')
    if (source / 'scripts/build-torrent-runtime.py').is_file():
        run([sys.executable, 'scripts/build-torrent-runtime.py'], 'torrent-runtime')
    run(['xcodebuild', '-project', 'uniplayer.xcodeproj', '-scheme', 'uniplayer', '-configuration', 'Debug',
         '-derivedDataPath', str(plan.output / 'TestsDerivedData'), 'CODE_SIGNING_ALLOWED=NO',
         '-parallel-testing-enabled', 'NO', 'test'], 'app-tests')
    run([sys.executable, 'scripts/release-macos.py', '--build', plan.build, '--profile', profile,
         '--keychain', str(keychain), '--identity', signing_identity(), '--output', str(plan.output)], 'package')
    return write_manifest(plan.output, plan.tag, plan.source, plan.version, plan.build)


def ensure_profile(plan, profile, keychain, loader=None):
    if profile_ready(profile, keychain):
        return
    loader = Path(loader) if loader else plan.root.parent / 'scripts/release.sh'
    if not loader.is_file():
        raise ReleaseError('Prepare a local notarytool profile, or specify --credential-loader')
    env = build_environment()
    env['UNIPLAYER_NOTARY_KEYCHAIN'] = str(keychain)
    if os.environ.get('UNIPLAYER_ENV_FILE'):
        env['UNIPLAYER_ENV_FILE'] = os.environ['UNIPLAYER_ENV_FILE']
    result = subprocess.run(['bash', str(loader), '--profile', profile, '--profile-only'],
                            env=env, capture_output=True, text=True)
    if result.returncode or not profile_ready(profile, keychain):
        raise ReleaseError('Local notarization profile setup failed; inspect credentials with the owner; values are hidden')


def push_source(plan, client):
    assert_source(plan)
    remote_state(plan, client)
    git(plan.root, 'push', 'origin', f'{plan.source}:refs/heads/main')  # Honors hooks; never force.
    local_tag = git(plan.root, 'rev-parse', '--verify', '--quiet', f'refs/tags/{plan.tag}^{{commit}}', optional=True)
    if not local_tag:
        git(plan.root, 'tag', plan.tag, plan.source)
    elif local_tag != plan.source:
        raise ReleaseError('Local tag changed; publication stopped')
    git(plan.root, 'push', 'origin', f'refs/tags/{plan.tag}:refs/tags/{plan.tag}')
    if client.tag_commit(plan.tag) != plan.source:
        raise ReleaseError('Remote tag does not match the verified package')


def resume_published(client, tag, output):
    version_tuple(tag)
    assert_not_older(tag, client.latest())
    value = client.release(tag)
    if not value or value['draft'] or value['prerelease']:
        raise ReleaseError('--resume requires an existing published stable release')
    source = client.tag_commit(tag)
    import base64
    config = client.api(f'repos/{client.repository}/contents/Configs/Deployment.xcconfig?ref={tag}')
    text = base64.b64decode(config['content']).decode()
    version = re.search(r'^MARKETING_VERSION\s*=\s*(\S+)', text, re.M)[1]
    build = re.search(r'^CURRENT_PROJECT_VERSION\s*=\s*([1-9]\d*)', text, re.M)[1]
    output = Path(output)
    client.download(tag, output, [f'UniPlayer-{version}-universal.dmg', 'SHA256SUMS.txt', MANIFEST])
    bundle = Bundle.load(output, tag, source, version, build)
    return publish_bundle(client, bundle, 'Published-release recovery; existing notes unchanged')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Readiness only: no profile setup, build, push, publication or deletion')
    parser.add_argument('--resume', metavar='TAG', help='Finish Homebrew/retention for an already published release; no rebuild or push')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--profile', default='uniplayer-notary')
    parser.add_argument('--keychain', type=Path, default=Path(os.environ.get('UNIPLAYER_NOTARY_KEYCHAIN',
                        str(Path.home() / 'Library/Keychains/login.keychain-db'))))
    parser.add_argument('--credential-loader', type=Path)
    args = parser.parse_args()
    client = GitHub('xiaolai/uniplayer', cli_auth=True)
    if args.resume:
        if args.check:
            parser.error('--check and --resume are separate modes')
        with release_lock(ROOT):
            target = args.output or ROOT.parent / 'release-artifacts' / args.resume / 'recovery'
            result = resume_published(client, args.resume, target)
    else:
        plan = plan_for(output=args.output)
        if args.check:
            report = readiness(plan, client, args.profile, args.keychain)
            print(json.dumps(report, indent=2))
            return 0 if report['ready'] else 1
        with release_lock(ROOT):
            assert_source(plan)
            validate_origin(plan, client.repository)
            if remote_state(plan, client):
                result = resume_published(client, plan.tag, plan.output)
            else:
                ensure_profile(plan, args.profile, args.keychain, args.credential_loader)
                report = readiness(plan, client, args.profile, args.keychain)
                if not report['ready']:
                    raise ReleaseError('; '.join(report['issues']))
                bundle = build_candidate(plan, client, args.profile, args.keychain)
                push_source(plan, client)
                result = publish_bundle(client, bundle, notes_for(plan.version, plan.root))
    print('Release and Homebrew verified; newest published release retained:', result['html_url'])
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f'local release: {error}', file=sys.stderr)
        sys.exit(1)
