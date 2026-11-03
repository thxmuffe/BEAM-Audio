"""Verify certificate and hostname checks with a private, uninstalled test CA."""
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import sys

from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location('relay_smoke', Path(__file__).with_name('relay-smoke.py'))
r = module_from_spec(spec)
spec.loader.exec_module(r)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def main():
    openssl = shutil.which('openssl') or r'C:\Program Files\Git\usr\bin\openssl.exe'
    build = (r.ROOT / 'builds/intermediates/tls-tests').resolve()
    build.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=build) as folder:
        assert Path(folder).resolve().is_relative_to(build)
        cert, key = Path(folder) / 'cert.pem', Path(folder) / 'key.pem'
        ca, ca_key = Path(folder) / 'ca.pem', Path(folder) / 'ca-key.pem'
        csr, extensions = Path(folder) / 'server.csr', Path(folder) / 'server.ext'
        subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(ca_key), '-out', str(ca), '-days', '1', '-subj', '/CN=Parvi local test CA',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([openssl, 'req', '-new', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(key), '-out', str(csr), '-subj', '/CN=localhost'],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        extensions.write_text('subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\n'
                              'keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
        subprocess.run([openssl, 'x509', '-req', '-in', str(csr), '-CA', str(ca), '-CAkey', str(ca_key),
            '-CAcreateserial', '-out', str(cert), '-days', '1', '-extfile', str(extensions)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        http_port, tls_port = free_port(), free_port()
        desk = r.start_desk(http_port, tls_port, cert, key)
        nodes = []
        try:
            if '--verbose' in sys.argv:
                ca_literal = r.json.dumps(str(ca).replace('\\', '/'))
                expression = ('application:ensure_all_started(ssl), R=ssl:connect("localhost",' + str(tls_port) +
                    ',[{verify,verify_peer},{cacertfile,' + ca_literal +
                    '},{customize_hostname_check,[{match_fun,public_key:pkix_verify_hostname_match_fun(https)}]}],5000),'
                    'case R of {ok,S}->io:format("Direct TLS verified~n"),ssl:close(S); E->io:format("TLS diagnosis: ~p~n",[E]) end,halt().')
                subprocess.run([str(r.ERL), '-noshell', '-eval', expression], check=True)
            a, b = [r.Node(f'wss://localhost:{tls_port}/relay/v1', {'PARVI_RELAY_CA_FILE': str(ca)}) for _ in range(2)]
            nodes.extend([a, b])
            initial = r.wait(a, lambda s: s['relay']['connected'])
            r.wait(b, lambda s: s['relay']['connected'])
            swarm = initial['swarms'][0]
            assert b.request('join_swarm', invitation=swarm['invitation'])['error'] is None
            assert a.request('send_swarm', swarm_id=swarm['id'], text='TLS relay')['error'] is None
            r.wait(b, lambda s: any(m['text'] == 'TLS relay' for m in r.swarm(s, swarm['id'])['messages']))
            bad_host = r.Node(f'wss://127.0.0.1:{tls_port}/relay/v1', {'PARVI_RELAY_CA_FILE': str(ca)})
            nodes.append(bad_host)
            r.wait(bad_host, lambda s: not s['relay']['connected'] and s['relay']['error'] is not None)
            untrusted = r.Node(f'wss://localhost:{tls_port}/relay/v1')
            nodes.append(untrusted)
            r.wait(untrusted, lambda s: not s['relay']['connected'] and s['relay']['error'] is not None)
            print('PASS: encrypted WSS admission/chat; wrong hostname rejected; untrusted certificate rejected; no trust-store changes')
        finally:
            for node in nodes:
                node.close()
            desk.terminate()
            desk.wait(timeout=5)


if __name__ == '__main__':
    main()
