#!/usr/bin/env python3
"""Exact runtime/lock, universal dependencies, notices and optional signatures."""
from pathlib import Path
import argparse,json,hashlib,subprocess
ROOT=Path(__file__).resolve().parents[1]
def check(runtime,signatures=False):
 lock=json.loads((ROOT/'RuntimeDependencies/Transmission.lock.json').read_text());manifest=json.loads((runtime/'manifest.json').read_text())
 for key in ['version','commit','rpcVersion','architectures','patches']:assert manifest[key]==lock[key],key
 assert manifest['patches']==[] and manifest['submodules'] and manifest['toolchain']
 assert (runtime/'Licenses/Transmission-COPYING').is_file()
 for name in ['transmission-daemon','TorrentRuntimeSupervisor']:
  path=runtime/name;assert len(manifest['builtBinaries'][name]['buildSha256'])==64;assert hashlib.sha256(path.read_bytes()).hexdigest()==manifest['builtBinaries'][name]['sha256'],name+' hash'
  assert set(subprocess.check_output(['lipo','-archs',path],text=True).split())==set(lock['architectures']),name+' architectures'
  dependencies=[line.strip().split(' (')[0] for line in subprocess.check_output(['otool','-L',path],text=True).splitlines() if line.startswith('\t')]
  assert all(dep.startswith(('/System/Library/','/usr/lib/')) for dep in dependencies),dependencies
  if signatures:subprocess.run(['codesign','--verify','--strict',str(path)],check=True)
 version=subprocess.check_output([runtime/'transmission-daemon','--version'],stderr=subprocess.STDOUT,text=True).strip()
 assert version.startswith('transmission-daemon '+lock['version']+' ') and lock['commit'][:10] in version,version
 return {'version':version,'runtime':str(runtime),'architectures':lock['architectures'],'hashesVerified':True,'systemDependenciesOnly':True,'signaturesVerified':signatures}
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('runtime',type=Path);p.add_argument('--signatures',action='store_true');a=p.parse_args();print(json.dumps(check(a.runtime,a.signatures),indent=2))
