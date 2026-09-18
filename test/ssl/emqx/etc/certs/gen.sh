#!/bin/sh
# Generates the CA, server and client certificates used by the QUIC (EMQX) tests.
# None of the keys are encrypted - do not use these files for anything but testing.
set -e
cd "$(dirname "$0")"

DAYS_CA=3650
DAYS_LEAF=825

rm -f cacert.pem cakey.pem cert.pem key.pem client-cert.pem client-key.pem \
      server.csr client.csr cacert.srl ext.cnf

# CA
openssl req -x509 -newkey rsa:2048 -nodes -days $DAYS_CA \
    -subj "/CN=Paho QUIC Test CA" -keyout cakey.pem -out cacert.pem

printf "subjectAltName=DNS:localhost,IP:127.0.0.1\n" > ext.cnf

# server certificate (CN=localhost, with SANs)
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout key.pem -out server.csr
openssl x509 -req -in server.csr -CA cacert.pem -CAkey cakey.pem -CAcreateserial \
    -days $DAYS_LEAF -extfile ext.cnf -out cert.pem

# client certificate (CN=localhost, with SANs)
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout client-key.pem -out client.csr
openssl x509 -req -in client.csr -CA cacert.pem -CAkey cakey.pem -CAcreateserial \
    -days $DAYS_LEAF -extfile ext.cnf -out client-cert.pem

rm -f server.csr client.csr cacert.srl ext.cnf

echo "Generated QUIC test certificates in $(pwd):"
openssl x509 -in cert.pem -noout -subject -enddate
openssl x509 -in client-cert.pem -noout -subject -enddate
