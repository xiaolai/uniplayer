#!/usr/bin/env python3
"""Xcode embed phase. Runtime is built explicitly and never fetched at launch."""
from pathlib import Path
import os,shutil,subprocess,json,hashlib
root=Path(os.environ['SRCROOT']);source=root/'build/TorrentRuntime'
assert (source/'manifest.json').is_file(), 'Run scripts/build-torrent-runtime.py before building UniPlayer'
lock=json.loads((root/'RuntimeDependencies/Transmission.lock.json').read_text());manifest=json.loads((source/'manifest.json').read_text())
assert manifest['commit']==lock['commit'] and manifest['patches']==[]
dest=Path(os.environ['TARGET_BUILD_DIR'])/os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']/'TorrentRuntime'
if dest.exists():shutil.rmtree(dest)
shutil.copytree(source,dest)
identity=os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
for name in ['transmission-daemon','TorrentRuntimeSupervisor']:
 path=dest/name
 assert hashlib.sha256(path.read_bytes()).hexdigest()==manifest['builtBinaries'][name]['sha256']
 if os.environ.get('CODE_SIGNING_ALLOWED')!='NO':
  args=['codesign','--force','--sign',identity,'--options','runtime']
  if identity!='-':args+=['--timestamp']
  subprocess.run(args+[str(path)],check=True)
 manifest['builtBinaries'][name]['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
shutil.copy2(root/'RuntimeDependencies/Transmission.lock.json',dest/'Transmission.lock.json')
