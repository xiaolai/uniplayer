#!/usr/bin/env python3
"""Build, Developer ID sign, notarize, and verify a universal UniPlayer DMG.

Credentials are supplied by the workspace scripts/release.sh keychain loader.
This script never publishes assets or changes the installed application.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def run(*args, **kwargs):
    print('Running:', args[0], args[1] if len(args) > 1 else '', flush=True)
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def notarize(path, profile, log, staple=None, keychain=None):
    keychain_options = ['--keychain', str(keychain)] if keychain else []
    result = subprocess.run(['xcrun', 'notarytool', 'submit', str(path),
                             '--keychain-profile', profile, '--wait',
                             '--timeout', '20m', '--output-format', 'json'] + keychain_options,
                            text=True, capture_output=True)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'Notary submission failed; inspect {log}: {result.stderr}')
    report = json.loads(result.stdout)
    issues_log = log.with_suffix('.issues.json')
    run('xcrun', 'notarytool', 'log', report['id'], '--keychain-profile', profile, *keychain_options, issues_log)
    if report.get('status') != 'Accepted':
        raise RuntimeError(f'Notarization status: {report.get("status")}; inspect {issues_log}')
    if json.loads(issues_log.read_text()).get('issues'):
        raise RuntimeError(f'Notarization reported issues; inspect {issues_log} before distribution')
    print('Notarization accepted:', path.name, report['id'], flush=True)
    run('xcrun', 'stapler', 'staple', staple or path)
    run('xcrun', 'stapler', 'validate', staple or path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True, type=int)
    parser.add_argument('--profile', required=True)
    parser.add_argument('--keychain', type=Path, help='Explicit keychain containing the notary profile')
    parser.add_argument('--identity', default=os.environ.get('UNIPLAYER_SIGN_IDENTITY'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--skip-build', action='store_true', help='Resume from the existing Release build')
    args = parser.parse_args()
    if args.build < 1:
        parser.error('build must be positive')
    root = Path(__file__).resolve().parents[1]
    config = dict(line.split(' = ', 1) for line in (root/'Configs/Deployment.xcconfig').read_text().splitlines()
                  if ' = ' in line)
    version = config['MARKETING_VERSION']
    if int(config['CURRENT_PROJECT_VERSION']) != args.build:
        parser.error('build must match Configs/Deployment.xcconfig')
    output = (args.output or root.parent/'release-artifacts'/version).resolve()
    output.mkdir(parents=True, exist_ok=True)
    derived = output/'DerivedData'
    if not args.identity:
        identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
        matches = [line.split('"')[1] for line in identities.splitlines() if '"Developer ID Application:' in line]
        if len(matches) != 1:
            parser.error('set UNIPLAYER_SIGN_IDENTITY to select one Developer ID Application identity')
        args.identity = matches[0]
    if not args.identity.startswith('Developer ID Application:'):
        parser.error('a Developer ID Application identity is required')
    if not args.skip_build:
        with (output/'build.log').open('w') as log:
            run('xcodebuild', '-project', root/'uniplayer.xcodeproj', '-scheme', 'uniplayer',
                '-configuration', 'Release', '-derivedDataPath', derived,
                'ONLY_ACTIVE_ARCH=NO', 'ARCHS=arm64 x86_64', 'CODE_SIGNING_ALLOWED=NO',
                'build', cwd=root, stdout=log, stderr=subprocess.STDOUT)
    built = derived/'Build/Products/Release/UniPlayer.app'
    stage = output/'stage'
    stage.mkdir(exist_ok=True)
    app = stage/'UniPlayer.app'
    if app.exists():
        shutil.rmtree(app)  # Only this script's named, rebuildable staging bundle.
    run('ditto', built, app)
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == version
    assert info['CFBundleVersion'] == str(args.build)
    rating_script = app/'Contents/Resources/NetflixRatings.js'
    assert rating_script.is_file() and 'uniPlayerRatings' in rating_script.read_text(), 'Netflix rating script missing from release'
    architectures = subprocess.check_output(['lipo', '-archs', str(app/'Contents/MacOS/UniPlayer')], text=True).split()
    assert set(architectures) == {'arm64', 'x86_64'}, architectures
    app_entitlements = root/'uniplayer/UniPlayer.entitlements'
    extension_entitlements = root/'OpenInUniPlayer/OpenInUniPlayer.entitlements'

    def sign(path, entitlements=None):
        command = ['codesign', '--force', '--sign', args.identity, '--timestamp=http://timestamp.apple.com/ts01', '--options', 'runtime']
        if entitlements:
            command += ['--entitlements', str(entitlements)]
        command.append(str(path))
        for attempt in range(3):
            result = subprocess.run(command, text=True, capture_output=True)
            print(result.stdout, result.stderr, end='', flush=True)
            if result.returncode == 0:
                return
            if 'timestamp' not in result.stderr.lower() or attempt == 2:
                raise subprocess.CalledProcessError(result.returncode, command)
            print('Retrying Apple timestamp request', attempt + 1, flush=True)

    # Sign nested code from the inside out, without --deep signing or copying
    # app entitlements onto shared libraries. Bundle signing comes afterwards.
    bundles = [p for p in app.rglob('*') if p.is_dir() and not p.is_symlink()
               and p.suffix in {'.framework', '.xpc', '.appex', '.app'}]
    # Signing a bundle's main executable implicitly signs its whole bundle.
    # Defer those entry points until all child bundles have been signed.
    entrypoints = set()
    for bundle in [app] + bundles:
        for metadata in [bundle/'Contents/Info.plist', bundle/'Resources/Info.plist']:
            if metadata.exists():
                executable = plistlib.loads(metadata.read_bytes()).get('CFBundleExecutable')
                if executable:
                    entrypoints.add((bundle/'Contents/MacOS'/executable).resolve())
                    entrypoints.add((bundle/executable).resolve())
                break
    magic = {bytes.fromhex(v) for v in ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
                                      'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
    for path in sorted(app.rglob('*')):
        if not path.is_file() or path.is_symlink() or path.resolve() in entrypoints:
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in magic:
                continue
        header = subprocess.check_output(['otool', '-hv', str(path)], text=True)
        sign(path, app_entitlements if 'EXECUTE' in header else None)
    for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        sign(bundle, extension_entitlements if bundle.suffix == '.appex' else
             app_entitlements if bundle.suffix in {'.app', '.xpc'} else None)
    sign(app, app_entitlements)
    run('codesign', '--verify', '--deep', '--strict', app)
    archive = output/'UniPlayer-notary.zip'
    archive.unlink(missing_ok=True)
    run('ditto', '-c', '-k', '--keepParent', app, archive)
    notarize(archive, args.profile, output/'app-notary.json', staple=app, keychain=args.keychain)
    # ZIP submissions notarize the enclosed app; tickets staple to that app.
    # The ZIP itself cannot carry a stapled ticket.
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    # The tiny alternate Finder handler opens files in the HUD window. It is a
    # separate app because Finder's Open With lists apps, not modes.
    helper = stage/'UniPlayer HUD.app'
    if helper.exists():
        shutil.rmtree(helper)
    run('python3', root/'scripts/build-hud-helper.py',
        '--app', app, '--output', helper, '--identity', args.identity,
        '--archs', 'arm64', 'x86_64')
    helper_architectures = subprocess.check_output(
        ['lipo', '-archs', str(helper/'Contents/MacOS/UniPlayer HUD')], text=True).split()
    assert set(helper_architectures) == {'arm64', 'x86_64'}, helper_architectures
    run('codesign', '--verify', '--deep', '--strict', helper)
    applications = stage/'Applications'
    if not applications.exists():
        applications.symlink_to('/Applications')
    dmg = output/f'UniPlayer-{version}-universal.dmg'
    dmg.unlink(missing_ok=True)
    run('hdiutil', 'create', '-volname', f'UniPlayer {version}', '-srcfolder', stage,
        '-format', 'UDZO', dmg)
    sign(dmg)
    notarize(dmg, args.profile, output/'dmg-notary.json', keychain=args.keychain)
    run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg)
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (output/'SHA256SUMS.txt').write_text(f'{digest}  {dmg.name}\n')
    print(f'Release ready: {dmg}\nSHA-256: {digest}', flush=True)


if __name__ == '__main__':
    main()
