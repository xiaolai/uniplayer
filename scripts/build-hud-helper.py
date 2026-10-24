#!/usr/bin/env python3
"""Build the tiny UniPlayer HUD Finder handler.

The helper registers as an alternate viewer for UniPlayer's document types and
forwards Finder opens to UniPlayer through `uniplayer://open?...&hud=1`. The
main app keeps the real playback surface; this bundle only carries a document
type declaration and a launcher.
"""
from __future__ import annotations

import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'UniPlayerHUD' / 'main.swift'
HELPER_NAME = 'UniPlayer HUD'
BUNDLE_ID = 'com.lixiaolai.uniplayer.hud'
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')


def run(*command: str) -> None:
    subprocess.run([str(part) for part in command], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path,
                        help='built UniPlayer.app to inherit document types and version from')
    parser.add_argument('--output', required=True, type=Path,
                        help='path of the UniPlayer HUD.app to create')
    parser.add_argument('--identity', default='-',
                        help='codesign identity; the default is ad-hoc')
    parser.add_argument('--archs', nargs='+', default=['arm64'],
                        help='binary architectures (release passes arm64 x86_64)')
    parser.add_argument('--register', action='store_true',
                        help='register the helper with LaunchServices')
    args = parser.parse_args()

    app_info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    document_types = [
        dict(entry, LSHandlerRank='Alternate')
        for entry in app_info.get('CFBundleDocumentTypes', [])
        if 'public.folder' not in entry.get('LSItemContentTypes', [])
    ]
    if not document_types:
        raise SystemExit('the main app declares no document types to inherit')

    contents = args.output / 'Contents'
    if args.output.exists():
        shutil.rmtree(args.output)
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()

    binary = contents / 'MacOS' / HELPER_NAME
    version = app_info.get('LSMinimumSystemVersion', '27.0')
    compiled = []
    for arch in args.archs:
        slice = contents / 'MacOS' / f'.{HELPER_NAME}-{arch}'
        run('xcrun', 'swiftc', '-O', '-framework', 'AppKit',
            '-target', f'{arch}-apple-macosx{version}', '-o', slice, SOURCE)
        compiled.append(slice)
    if len(compiled) == 1:
        compiled[0].rename(binary)
    else:
        run('lipo', '-create', '-output', binary, *compiled)
        for slice in compiled:
            slice.unlink()

    info = {
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleDisplayName': HELPER_NAME,
        'CFBundleExecutable': HELPER_NAME,
        'CFBundleIdentifier': BUNDLE_ID,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': HELPER_NAME,
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': app_info['CFBundleShortVersionString'],
        'CFBundleVersion': app_info['CFBundleVersion'],
        'CFBundleDocumentTypes': document_types,
        'LSMinimumSystemVersion': app_info.get('LSMinimumSystemVersion', '27.0'),
        'LSUIElement': True,
        'NSHighResolutionCapable': True,
        'NSPrincipalClass': 'NSApplication',
    }

    icon_name = app_info.get('CFBundleIconFile')
    if icon_name:
        icon = args.app / 'Contents/Resources' / f'{icon_name}.icns'
        if icon.is_file():
            shutil.copy2(icon, contents / 'Resources' / icon.name)
            info['CFBundleIconFile'] = icon_name

    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))

    if args.identity == '-':
        run('codesign', '--force', '--sign', '-', args.output)
    else:
        run('codesign', '--force', '--options', 'runtime', '--timestamp',
            '--sign', args.identity, args.output)
    run('codesign', '--verify', '--strict', '--deep', args.output)

    if args.register:
        run(LSREGISTER, '-f', args.output)

    print(f'{HELPER_NAME} ready: {args.output}')


if __name__ == '__main__':
    main()
