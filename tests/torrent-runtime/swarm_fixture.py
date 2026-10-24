#!/usr/bin/env python3
"""Controlled swarm for native bridge/player tests. No Internet peers or user profiles."""
from pathlib import Path
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import base64,hashlib,json,os,secrets,signal,socket,struct,subprocess,threading,time,urllib.request,urllib.parse,urllib.error,sys
BIN=Path(sys.argv[1]);RUN=Path(sys.argv[2]);OUT=RUN
RUN.mkdir(parents=True,exist_ok=True)
PARENT_PID=os.getppid()
processes=[];logs=[];announces=[];seed_port=None;relay_sockets=[]
def enc(v):
 if isinstance(v,int):return b'i'+str(v).encode()+b'e'
 if isinstance(v,str):v=v.encode()
 if isinstance(v,bytes):return str(len(v)).encode()+b':'+v
 if isinstance(v,list):return b'l'+b''.join(map(enc,v))+b'e'
 if isinstance(v,dict):return b'd'+b''.join(enc(k)+enc(v[k]) for k in sorted(v))+b'e'
 raise TypeError(type(v))
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
class Tracker(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  q=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query,encoding='latin1')
  peer=q.get('peer_id',[''])[0].encode('latin1'); ua=self.headers.get('User-Agent','')
  announces.append({'userAgent':ua,'peerIDPrefix':peer[:8].decode('ascii','replace'),'event':q.get('event',[''])[0]})
  peers=b'' if not seed_port or q.get('port',[''])[0]==str(seed_port) else socket.inet_aton('127.0.0.1')+struct.pack('!H',seed_port)
  body=enc({'interval':1,'min interval':1,'complete':1,'incomplete':1,'peers':peers,'warning message':'Controlled tracker warning'})
  self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
server=ThreadingHTTPServer(('127.0.0.1',0),Tracker);threading.Thread(target=server.serve_forever,daemon=True).start()
tracker=f'http://127.0.0.1:{server.server_port}/announce'
class Client:
 def __init__(self,name,limit=128):
  self.home=RUN/name;self.home.mkdir();self.data=self.home/'data';self.data.mkdir();self.peer=port();self.rpc=port();self.sid=''
  self.password=secrets.token_hex(16)
  settings={'download_dir':str(self.data),'incomplete_dir_enabled':False,'rename_partial_files':False,
   'dht_enabled':False,'pex_enabled':False,'lpd_enabled':False,'port_forwarding_enabled':False,
   'bind_address_ipv4':'127.0.0.1','bind_address_ipv6':'::1','peer_port':self.peer,'peer_port_random_on_start':False,'utp_enabled':False,
   'rpc_enabled':True,'rpc_bind_address':'127.0.0.1','rpc_port':self.rpc,'rpc_authentication_required':True,'rpc_username':'fixture','rpc_password':self.password,
   'rpc_whitelist_enabled':True,'rpc_whitelist':'127.0.0.1','rpc_host_whitelist_enabled':True,'rpc_host_whitelist':'localhost',
   'download_queue_enabled':False,'seed_queue_enabled':False,'speed_limit_down_enabled':True,'speed_limit_down':limit,
   'speed_limit_up_enabled':True,'speed_limit_up':512,'peer_limit_global':20,'peer_limit_per_torrent':10,'message_level':1}
  config=self.home/'settings.json';config.write_text(json.dumps(settings));config.chmod(0o600)
  log=(self.home/'daemon.log').open('wb');logs.append(log)
  self.process=subprocess.Popen([str(BIN),'--foreground','--config-dir',str(self.home),'--log-level','error'],stdout=log,stderr=subprocess.STDOUT);processes.append(self.process)
  for _ in range(100):
   if self.process.poll() is not None:raise RuntimeError(name+' daemon exited; inspect isolated log')
   try:self.session=self.call('session_get',{});break
   except (OSError,urllib.error.URLError):time.sleep(.1)
  else:raise TimeoutError(name+' RPC startup')
 def call(self,method,params):
  body=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode()
  for _ in range(2):
   request=urllib.request.Request(f'http://127.0.0.1:{self.rpc}/transmission/rpc',body,headers={'Content-Type':'application/json','X-Transmission-Session-Id':self.sid,'Authorization':'Basic '+base64.b64encode(('fixture:'+self.password).encode()).decode()})
   try:
    with urllib.request.urlopen(request,timeout=3) as response:result=json.load(response)
    if 'error' in result:raise RuntimeError(str(result['error']))
    return result['result']
   except urllib.error.HTTPError as e:
    if e.code!=409:raise
    self.sid=e.headers['X-Transmission-Session-Id']
  raise RuntimeError('CSRF retry failed')
 def add(self,**params):
  r=self.call('torrent_add',params);return (r.get('torrent_added') or r.get('torrent_duplicate'))['id']
 def get(self,id):
  return self.call('torrent_get',{'ids':[id],'fields':['id','name','status','metadata_percent_complete','pieces','piece_count','piece_size','availability','wanted','downloaded_ever','uploaded_ever','peers_connected','peers','is_private','tracker_stats','percent_done','error_string','sequential_download','sequential_download_from_piece']})['torrents'][0]
def wait_for(fn,timeout=12):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  r=fn()
  if r:return r
  time.sleep(.05)
 raise TimeoutError('controlled fixture deadline')
def has_piece(t,n):
 b=base64.b64decode(t['pieces']);return bool(b[n//8] & (128>>(n%8)))
def connect_incoming_peers(left,right,info_hash):
 # Stock Transmission intentionally rejects loopback peers learned from trackers.
 # Two fixture-owned incoming connections relay normal peer messages without
 # patching the engine or adding a LAN/public peer. This is transport qualification,
 # not evidence of private-tracker membership acceptance.
 sockets=[]
 for client in [left,right]:
  sock=socket.create_connection(('127.0.0.1',client.peer),timeout=3);sock.settimeout(3)
  peer_id=b'-FX0001-'+secrets.token_bytes(12)
  reserved=bytearray(8);reserved[5]=0x10 # BEP 10, needed for metadata exchange
  sock.sendall(b'\x13BitTorrent protocol'+bytes(reserved)+info_hash+peer_id)
  response=b''
  while len(response)<68:
   chunk=sock.recv(68-len(response))
   if not chunk:raise RuntimeError('peer closed during fixture handshake')
   response+=chunk
  assert response[:20]==b'\x13BitTorrent protocol' and response[28:48]==info_hash
  sock.settimeout(None);sockets.append(sock);relay_sockets.append(sock)
 def forward(source,destination):
  try:
   while True:
    data=source.recv(65536)
    if not data:break
    destination.sendall(data)
  except OSError:pass
  finally:
   for item in [source,destination]:
    try:item.shutdown(socket.SHUT_RDWR)
    except OSError:pass
 for source,destination in [sockets,sockets[::-1]]:threading.Thread(target=forward,args=(source,destination),daemon=True).start()


try:
 data=Path(sys.argv[3]).read_bytes();piece=65536
 info={'name':'fixture.mp4','length':len(data),'piece length':piece,'pieces':b''.join(hashlib.sha1(data[i:i+piece]).digest() for i in range(0,len(data),piece)),'private':1}
 if len(sys.argv)>4 and sys.argv[4]=='public':info.pop('private',None)
 if len(sys.argv)>4 and sys.argv[4]=='multi':
  prefix=os.urandom(10003);padding=bytes(7777);combined=prefix+padding+data
  info={'name':'pack','files':[{'length':len(prefix),'path':['intro.bin']},{'length':len(padding),'path':['.pad','7777'],'attr':'p'},{'length':len(data),'path':['episode.mp4']}],'piece length':piece,'pieces':b''.join(hashlib.sha1(combined[i:i+piece]).digest() for i in range(0,len(combined),piece)),'private':1}
 metainfo=enc({'announce':tracker,'info':info})
 seeder=Client('seed',8192);seed_port=seeder.peer
 if 'files' in info:
  folder=seeder.data/'pack';(folder/'.pad').mkdir(parents=True);(folder/'intro.bin').write_bytes(prefix);(folder/'.pad/7777').write_bytes(padding);(folder/'episode.mp4').write_bytes(data)
 else:(seeder.data/info['name']).write_bytes(data)
 tid=seeder.add(metainfo=base64.b64encode(metainfo).decode(),paused=False,sequential_download=True)
 wait_for(lambda:seeder.get(tid)['percent_done']==1,20)
 class Control(BaseHTTPRequestHandler):
  def log_message(self,*args):pass
  def do_GET(self):
   target=int(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['port'][0])
   class Peer:peer=target
   try:connect_incoming_peers(seeder,Peer(),hashlib.sha1(enc(info)).digest());status=200
   except Exception:status=500
   self.send_response(status);self.send_header('Content-Length','0');self.end_headers()
 control=ThreadingHTTPServer(('127.0.0.1',0),Control);threading.Thread(target=control.serve_forever,daemon=True).start()
 (RUN/'ready.json').write_text(json.dumps({'metainfo':base64.b64encode(metainfo).decode(),'relayControlPort':control.server_port,'sha256':hashlib.sha256(data).hexdigest()}))
 def stop(*args):raise KeyboardInterrupt()
 signal.signal(signal.SIGTERM,stop)
 while os.getppid()==PARENT_PID:time.sleep(.2)
except KeyboardInterrupt:pass
finally:
 for sock in relay_sockets:
  try:sock.close()
  except OSError:pass
 for child in processes:
  if child.poll() is None:child.terminate()
 for child in processes:
  try:child.wait(timeout=5)
  except subprocess.TimeoutExpired:child.kill();child.wait()
 for log in logs:log.close()
 (RUN/'tracker-identity.json').write_text(json.dumps({'userAgents':sorted(set(a['userAgent'] for a in announces)),'prefixes':sorted(set(a['peerIDPrefix'] for a in announces))}))
