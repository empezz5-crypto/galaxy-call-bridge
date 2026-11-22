#!/usr/bin/python3
"""Reconnect only the previously enrolled, authenticated Galaxy. Never pairs devices."""
import json, os, pathlib, re, subprocess, sys
ADB='/opt/homebrew/bin/adb'
ROOT=pathlib.Path.home()/'Library/Application Support/GalaxyCallBridge'

def adb(*args):
    try:
        return subprocess.run([ADB,*args],capture_output=True,text=True,timeout=4,
            env={**os.environ,'ADB_SERVER_SOCKET':'tcp:127.0.0.1:5037'}).stdout.strip()
    except subprocess.TimeoutExpired:
        return ''

def main():
    trusted=ROOT/'trusted-device.json'
    if not trusted.exists(): return 1
    config=json.loads(trusted.read_text())
    identity=config['serial']
    if len(sys.argv)==3 and sys.argv[1]=='--owns-endpoint':
        return 0 if sys.argv[2] in (identity, config.get('endpoint'), config.get('previousEndpoint')) else 1
    def remember(endpoint):
        if endpoint == identity or config.get('endpoint') == endpoint:
            return
        config['previousEndpoint']=config.get('endpoint')
        config['endpoint']=endpoint
        tmp=trusted.with_name(trusted.name+'.'+str(os.getpid())+'.tmp')
        tmp.write_text(json.dumps(config));tmp.chmod(0o600);tmp.replace(trusted)
    def match(endpoint):
        return adb('-s',endpoint,'shell','getprop','ro.serialno')==identity and adb('-s',endpoint,'shell','getprop','ro.product.model')=='SM-S931N'
    def verified_tls(endpoint):
        port = endpoint.rsplit(':', 1)[-1]
        if not port.isdigit() or port == '5555':
            return False
        if adb('-s', endpoint, 'shell', 'getprop', 'service.adb.tls.port') == port:
            return True
        state = adb('-s', endpoint, 'shell', 'dumpsys', 'adb')
        return bool(re.search(r'^\s*tls_port=' + port + r'\s*$', state, re.MULTILINE))

    devices=[line.split()[0] for line in adb('devices').splitlines()[1:] if len(line.split())>=2 and line.split()[1]=='device']
    for endpoint in sorted(devices, key=lambda item: item == identity):
        if (endpoint == identity or (endpoint == config.get('endpoint') and verified_tls(endpoint))) and match(endpoint):
            remember(endpoint);print(endpoint);return 0
    service_type = '_adb-tls-connect._tcp'
    services = {}
    for line in adb('mdns', 'services').splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0].startswith('adb-' + identity + '-') and fields[1].rstrip('.') == service_type:
            services[fields[0] + '.' + service_type] = fields[-1]
    for endpoint in devices:
        address = services.get(endpoint.rstrip('.'))
        if (address or endpoint in services.values()) and match(endpoint):
            remember(address or endpoint)
            print(endpoint)
            return 0
    candidates = [*services.values(), config.get('endpoint')]
    for endpoint in dict.fromkeys(candidates):
        if not endpoint or not endpoint.rsplit(':', 1)[-1].isdigit() or endpoint.endswith(':5555'):
            continue
        adb('connect', endpoint)
        if (endpoint in services.values() or verified_tls(endpoint)) and match(endpoint):
            remember(endpoint)
            print(endpoint)
            return 0
    return 1
if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,KeyError):sys.exit(1)
