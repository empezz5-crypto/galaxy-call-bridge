import importlib.util, pathlib, tempfile, json, contextlib, io
spec=importlib.util.spec_from_file_location('discovery',pathlib.Path(__file__).parents[1]/'audio-experiment/discover-device.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as d:
 m.ROOT=pathlib.Path(d)
 (m.ROOT/'trusted-device.json').write_text(json.dumps({'serial':'TRUSTED','endpoint':'192.0.2.1:12345'}))
 actions=[]
 def fake(*args):
  actions.append(args)
  if args==('devices',):return 'List of devices attached\nforeign:12345 device\n'
  if args==('mdns','services'):return 'adb-OTHER-abc _adb-tls-connect._tcp 192.0.2.3:12345\nadb-TRUSTED-abc _adb-tls-connect._tcp 192.0.2.2:12345'
  if args[:2]==('-s','192.0.2.2:12345'):return 'TRUSTED' if args[-1]=='ro.serialno' else 'SM-S931N'
  return 'OTHER'
 m.adb=fake
 with contextlib.redirect_stdout(io.StringIO()) as output:result=m.main()
 assert result==0 and output.getvalue().strip()=='192.0.2.2:12345'
 assert ('connect','192.0.2.3:12345') not in actions
 assert not any(a[0]=='pair' for a in actions)
 assert json.loads((m.ROOT/'trusted-device.json').read_text())['endpoint']=='192.0.2.2:12345'
 m.adb=lambda *args:''
 with contextlib.redirect_stdout(io.StringIO()):assert m.main()==1
 print('PASS trusted identity selection, changed TLS endpoint, foreign device exclusion, offline; no real ADB operations')
