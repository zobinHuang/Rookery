#!/bin/zsh
# Create a self-signed code-signing identity so local builds keep a stable signature,
# which keeps the Accessibility grant across rebuilds.
set -euo pipefail

identity=${ROOKERY_SIGN_IDENTITY:-Rookery Development}
keychain=${1:-$HOME/Library/Keychains/login.keychain-db}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

if security find-identity -p codesigning "$keychain" | grep -q "\"$identity\""; then
    echo "identity \"$identity\" already exists"
    exit 0
fi

cat > "$work_dir/openssl.cnf" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identity
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONFIG

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$work_dir/openssl.cnf" \
    -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -passout pass:rookery \
    -inkey "$work_dir/key.pem" -in "$work_dir/cert.pem" -out "$work_dir/identity.p12"
security import "$work_dir/identity.p12" -k "$keychain" -P rookery -T /usr/bin/codesign

echo "created identity \"$identity\" in $keychain"
