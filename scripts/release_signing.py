#!/usr/bin/env python3
"""Import CI signing material into a disposable keychain, then restore its list.

Secrets are read only from step-scoped environment variables. Command output is
captured, never echoed, and Xcode runs in a later step without those variables.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile

REQUIRED = ['MACOS_CERTIFICATE_P12_BASE64', 'MACOS_CERTIFICATE_PASSWORD',
            'APPLE_ID', 'APP_SPECIFIC_PASSWORD', 'TEAM_ID']
PROFILE = 'uniplayer-ci-notary'


class SigningError(RuntimeError):
    pass


def credentials(env):
    missing = [name for name in REQUIRED if not env.get(name)]
    if missing:
        raise SigningError('Missing release secrets: ' + ', '.join(missing))
    try:
        certificate = base64.b64decode(''.join(env[REQUIRED[0]].split()), validate=True)
    except ValueError:
        raise SigningError('MACOS_CERTIFICATE_P12_BASE64 is not valid Base64') from None
    if not certificate:
        raise SigningError('Signing certificate is empty')
    return certificate


def quiet(args, message):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Apple tools can repeat arguments in errors. Do not print their output.
        raise SigningError(message)
    return result.stdout


def save_state(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)


def setup(state_path, env=os.environ, run=quiet):
    certificate = credentials(env)
    runner_temp = Path(env['RUNNER_TEMP']).resolve(strict=True)
    state_path = Path(state_path)
    if state_path.exists() or state_path.is_symlink():
        raise SigningError('Signing state already exists; clean it up before retrying')
    original = shlex.split(run(['security', 'list-keychains', '-d', 'user'],
                              'Could not read the user keychain search list'))
    directory = Path(tempfile.mkdtemp(prefix='uniplayer-signing-', dir=runner_temp))
    os.chmod(directory, 0o700)
    keychain = directory / 'signing.keychain-db'
    certificate_path = directory / 'certificate.p12'
    state = {'schema': 1, 'directory': str(directory), 'keychain': str(keychain), 'original': original}
    save_state(state_path, state)  # Cleanup can recover every subsequent partial failure.
    password = secrets.token_urlsafe(32)
    fd = os.open(certificate_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(certificate)
        run(['security', 'create-keychain', '-p', password, str(keychain)], 'Could not create signing keychain')
        run(['security', 'set-keychain-settings', '-lut', '21600', str(keychain)], 'Could not configure signing keychain')
        run(['security', 'unlock-keychain', '-p', password, str(keychain)], 'Could not unlock signing keychain')
        run(['security', 'list-keychains', '-d', 'user', '-s', str(keychain), *original],
            'Could not extend the keychain search list')
        run(['security', 'import', str(certificate_path), '-P', env['MACOS_CERTIFICATE_PASSWORD'],
             '-k', str(keychain), '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'],
            'Could not import the Developer ID certificate/private key')
        run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s',
             '-k', password, str(keychain)], 'Could not allow noninteractive signing')
        run(['xcrun', 'notarytool', 'store-credentials', PROFILE, '--keychain', str(keychain),
             '--apple-id', env['APPLE_ID'], '--team-id', env['TEAM_ID'],
             '--password', env['APP_SPECIFIC_PASSWORD']], 'Could not store or validate notarization credentials')
    finally:
        certificate_path.unlink(missing_ok=True)
    # Only non-secret identifiers cross the step boundary.
    if env.get('GITHUB_OUTPUT'):
        with open(env['GITHUB_OUTPUT'], 'a') as stream:
            stream.write(f'keychain={keychain}\nprofile={PROFILE}\n')


def cleanup(state_path, env=os.environ, run=quiet):
    state_path = Path(state_path)
    if not state_path.exists():
        return
    if state_path.is_symlink():
        raise SigningError('Refusing symlinked signing state')
    state = json.loads(state_path.read_text())
    directory = Path(state['directory'])
    keychain = Path(state['keychain'])
    runner_temp = Path(env['RUNNER_TEMP']).resolve(strict=True)
    if (state.get('schema') != 1 or directory.is_symlink()
            or directory.resolve().parent != runner_temp or not directory.name.startswith('uniplayer-signing-')
            or keychain != directory / 'signing.keychain-db' or not isinstance(state.get('original'), list)
            or not all(isinstance(path, str) for path in state['original'])):
        raise SigningError('Unsafe signing cleanup state; nothing removed')
    # Restore first; never leave the search list pointing at a deleted keychain.
    run(['security', 'list-keychains', '-d', 'user', '-s', *state['original']],
        'Could not restore the original keychain search list')
    if keychain.exists():
        run(['security', 'delete-keychain', str(keychain)], 'Could not delete temporary signing keychain')
    shutil.rmtree(directory, ignore_errors=False)
    state_path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'setup', 'cleanup'])
    parser.add_argument('--state', type=Path)
    args = parser.parse_args()
    if args.command == 'check':
        credentials(os.environ)
        print('Required signing secrets are present; values hidden')
    elif args.state is None:
        parser.error('--state is required')
    elif args.command == 'setup':
        setup(args.state)
        print('Temporary signing keychain and notary profile ready')
    else:
        cleanup(args.state)
        print('Temporary signing material cleaned up')


if __name__ == '__main__':
    try:
        main()
    except (SigningError, OSError, ValueError, KeyError) as error:
        print(f'signing: {error}', file=sys.stderr)
        sys.exit(1)
