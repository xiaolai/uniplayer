#!/usr/bin/env python3
"""Build a pinned, unmodified universal Transmission; never touches user profiles."""
from pathlib import Path
import argparse,subprocess,json,hashlib,shutil,os
ROOT=Path(__file__).resolve().parents[1]
def run(args,**kw): return subprocess.run([str(x) for x in args],check=True,**kw)
def main():
 p=argparse.ArgumentParser();p.add_argument('--source',type=Path);p.add_argument('--output',type=Path,default=ROOT/'build/TorrentRuntime');p.add_argument('--jobs',default='6');a=p.parse_args()
 lock=json.loads((ROOT/'RuntimeDependencies/Transmission.lock.json').read_text());out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
 source=(a.source or ROOT/'build/torrent-runtime-source').resolve()
 if not source.exists():run(['git','clone','--branch',lock['version'],'--depth','1',lock['repository'],source])
 assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()==lock['commit'],'Unexpected Transmission revision'
 run(['git','diff','HEAD','--exit-code'],cwd=source);run(['git','submodule','update','--init','--recursive','--depth','1'],cwd=source)
 assert not subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=source,text=True).strip(),'Transmission source is modified'
 submodules=subprocess.check_output(['git','submodule','status','--recursive'],cwd=source,text=True).splitlines()
 for entry in submodules:
  assert entry.startswith(' '),'Unpinned Transmission submodule'
  module=source/entry.strip().split()[1]
  assert not subprocess.check_output(['git','status','--porcelain','--untracked-files=normal'],cwd=module,text=True).strip(),'Modified Transmission dependency'
 build=ROOT/'build/torrent-runtime'
 run(['cmake','-S',source,'-B',build,'-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_DEPLOYMENT_TARGET=27.0','-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64','-DENABLE_MAC=OFF','-DENABLE_GTK=OFF','-DENABLE_QT=OFF','-DENABLE_TESTS=OFF','-DENABLE_UTILS=OFF','-DENABLE_CLI=OFF','-DENABLE_DAEMON=ON','-DENABLE_NLS=OFF','-DRUN_CLANG_TIDY=OFF','-DUSE_SYSTEM_EVENT2=OFF','-DUSE_SYSTEM_PSL=OFF','-DUSE_SYSTEM_DEFLATE=OFF','-DUSE_SYSTEM_DHT=OFF','-DUSE_SYSTEM_MINIUPNPC=OFF','-DUSE_SYSTEM_NATPMP=OFF','-DUSE_SYSTEM_UTP=OFF','-DUSE_SYSTEM_B64=OFF','-DWITH_CRYPTO=ccrypto'])
 run(['cmake','--build',build,'--target','transmission-daemon','-j',a.jobs])
 shutil.copy2(build/'daemon/transmission-daemon',out/'transmission-daemon')
 slices=[]
 for arch in lock['architectures']:
  binary=build/f'TorrentRuntimeSupervisor-{arch}';run(['swiftc','-O','-target',f'{arch}-apple-macos27.0',ROOT/'torrent-runtime/Supervisor.swift','-o',binary]);slices.append(binary)
 run(['lipo','-create',*slices,'-output',out/'TorrentRuntimeSupervisor'])
 notices=out/'Licenses';notices.mkdir(exist_ok=True);shutil.copy2(source/'COPYING',notices/'Transmission-COPYING')
 shutil.copytree(source/'licenses',notices/'Transmission',dirs_exist_ok=True)
 deps=source/'third-party'
 for sub in deps.iterdir():
  if not sub.is_dir():continue
  for name in ['LICENSE','LICENSE.txt','COPYING','COPYING.txt','COPYRIGHT']:
   candidate=sub/name
   if candidate.is_file():shutil.copy2(candidate,notices/(sub.name+'-'+name))
 manifest={**lock,'builtBinaries':{},'toolchain':{name:subprocess.check_output(command,text=True).strip() for name,command in {'xcode':['xcodebuild','-version'],'clang':['xcrun','clang','--version'],'swift':['swiftc','--version'],'cmake':['cmake','--version'],'macOS':['sw_vers','-productVersion']}.items()}}
 for name in ['transmission-daemon','TorrentRuntimeSupervisor']:
  path=out/name;archs=subprocess.check_output(['lipo','-archs',path],text=True).split();assert set(archs)==set(lock['architectures'])
  libs='\n'.join(line for line in subprocess.check_output(['otool','-L',path],text=True).splitlines() if line.startswith('\t'))
  assert '/opt/homebrew/' not in libs and '/private/tmp/' not in libs and '/Users/' not in libs,'Nonportable dependency'
  manifest['builtBinaries'][name]={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'buildSha256':hashlib.sha256(path.read_bytes()).hexdigest(),'architectures':archs}
 manifest['submodules']=subprocess.check_output(['git','submodule','status','--recursive'],cwd=source,text=True).splitlines()
 manifest['actualVersion']=subprocess.check_output([out/'transmission-daemon','--version'],stderr=subprocess.STDOUT,text=True).strip();assert lock['version'] in manifest['actualVersion']
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print('Universal genuine Transmission runtime built:',out)
if __name__=='__main__':main()
