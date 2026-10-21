#!/bin/bash
# Crée UNE FOIS une identité de signature auto-signée « Plafond Dev » dans un
# trousseau dédié, et enregistre ses paramètres dans .signing.env (non versionné).
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_CN="Plafond Dev"
KC="$HOME/Library/Keychains/plafond-signing.keychain-db"
KCPASS="$(openssl rand -hex 16)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$SIGN_CN
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 3650 -nodes -config "$TMP/cert.cnf" 2>/dev/null
P12PASS="$(openssl rand -hex 8)"
openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/id.p12" -passout "pass:$P12PASS" -name "$SIGN_CN"

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/[" ]//g')

umask 077
printf 'SIGN_CN="%s"\nKC="%s"\nKCPASS="%s"\n' "$SIGN_CN" "$KC" "$KCPASS" > .signing.env
echo "✓ Identité « $SIGN_CN » créée ; paramètres dans .signing.env"
