#!/bin/bash
set -euo pipefail
python3 prepare-assets.py
tempdir=$(mktemp -d)
server_pid=''
trap 'if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi; rm -rf "$tempdir"' EXIT
cat > "$tempdir/openssl.cnf" <<'CONFIG'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
subjectAltName=IP:127.0.0.1
CONFIG
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$tempdir/openssl.cnf" -keyout "$tempdir/key.pem" -out "$tempdir/cert.pem" 2>/dev/null
openssl x509 -in "$tempdir/cert.pem" -outform DER -out "$tempdir/cert.der"
python3 transport-smoke-server.py "$tempdir/cert.pem" "$tempdir/key.pem" "$tempdir/ready" &
server_pid=$!
for attempt in {1..50}; do [ -f "$tempdir/ready" ] && break; sleep 0.1; done
[ -f "$tempdir/ready" ]
xcrun swiftc -parse-as-library PinnedWebSocket.swift TransportSmoke.swift -o "$tempdir/transport-smoke" -framework Network -framework Security -framework CryptoKit
"$tempdir/transport-smoke" "$tempdir/cert.der"
