"""Qualify stock IPC availability; shipping v1 uses authenticated loopback RPC."""
import base64,http.client,json,os,secrets,socket,subprocess,tempfile,time,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class UnixHTTP(http.client.HTTPConnection):
 def __init__(self,path):super().__init__('localhost',timeout=1);self.path=path
 def connect(self):self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);self.sock.settimeout(1);self.sock.connect(self.path)
class UnixCapabilityTests(unittest.TestCase):
 def test_real_stock_unix_rpc_authentication_and_effective_settings(self):
  with tempfile.TemporaryDirectory(prefix='up-ipc-',dir='/private/tmp') as directory:
   root=Path(directory);root.chmod(0o700);path=root/'rpc.sock';password=secrets.token_hex(24)
   settings={'rpc_enabled':True,'rpc_bind_address':'unix:'+str(path),'rpc_socket_mode':'0600','rpc_authentication_required':True,'rpc_username':'fixture','rpc_password':password,'rpc_whitelist_enabled':False,'dht_enabled':False,'pex_enabled':False,'lpd_enabled':False,'port_forwarding_enabled':False,'start_added_torrents':False,'peer_port_random_on_start':True,'message_level':0}
   config=root/'settings.json';config.write_text(json.dumps(settings));config.chmod(0o600)
   process=subprocess.Popen([str(ROOT/'build/TorrentRuntime/transmission-daemon'),'--foreground','--paused','--config-dir',str(root),'--log-level','critical'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   def request(headers):
    connection=UnixHTTP(str(path))
    try:
     body=json.dumps({'jsonrpc':'2.0','id':1,'method':'session_get','params':{'fields':['version','lpd_enabled','start_added_torrents','peer_port_random_on_start']}})
     connection.request('POST','/transmission/rpc',body,headers={'Content-Type':'application/json',**headers});response=connection.getresponse();return response.status,dict(response.getheaders()),response.read()
    finally:connection.close()
   try:
    for _ in range(100):
     if path.exists():break
     self.assertIsNone(process.poll());time.sleep(.05)
    status,_,_=request({});self.assertEqual(status,401)
    auth='Basic '+base64.b64encode(('fixture:'+password).encode()).decode()
    status,headers,_=request({'Authorization':auth});self.assertEqual(status,409)
    session=next(v for k,v in headers.items() if k.lower()=='x-transmission-session-id')
    status,_,data=request({'Authorization':auth,'X-Transmission-Session-Id':session});self.assertEqual(status,200)
    result=json.loads(data)['result'];self.assertIn('4.1.3 (838877323f)',result['version']);self.assertFalse(result['lpd_enabled']);self.assertFalse(result['start_added_torrents']);self.assertTrue(result['peer_port_random_on_start'])
    self.assertEqual(path.stat().st_mode & 0o777,0o600)
   finally:
    process.terminate()
    try:process.wait(timeout=6)
    except subprocess.TimeoutExpired:process.kill();process.wait()

if __name__ == '__main__': unittest.main()
