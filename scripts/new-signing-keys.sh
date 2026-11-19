#!/bin/bash
# Creates Imla's release signing keys and stores them in Bitwarden as one secure note:
#   - a self-signed code signing certificate (.p12, base64 in the note's text) and its password
#   - a Sparkle EdDSA key pair, which signs updates
# Nothing is written to disk outside a temporary directory that is removed on exit.
#
# Needs OpenSSL 3 or later, jq, and the Bitwarden CLI, logged in and unlocked
# (an exported BW_SESSION already counts):
#   bw config server https://your-vault.example   # self-hosted only
#   bw login
#   export BW_SESSION="$(bw unlock --raw)"
#   ./scripts/new-signing-keys.sh ["Imla release signing"]
#
# Make keys once: a new certificate resets every user's macOS permissions, and
# a new Sparkle key can't update apps signed for the old one.
set -euo pipefail
ITEM="${1:-Imla release signing}"

openssl version | grep -qE '^OpenSSL ([3-9]|[1-9][0-9])\.' || { echo "Needs OpenSSL 3 or later (macOS ships LibreSSL; try Homebrew's openssl@3)" >&2; exit 1; }
for tool in jq bw; do command -v "$tool" >/dev/null || { echo "Needs $tool" >&2; exit 1; }; done
[ "$(bw status | jq -r .status)" = unlocked ] || { echo "Unlock Bitwarden first: export BW_SESSION=\"\$(bw unlock --raw)\"" >&2; exit 1; }
if bw list items --search "$ITEM" | jq -e --arg n "$ITEM" 'any(.[]; .name == $n)' >/dev/null; then
    echo "\"$ITEM\" already exists in Bitwarden; not replacing it" >&2; exit 1
fi

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

# Code signing certificate. 20 years: codesign has no renewal story for self-signed identities.
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 \
    -subj "/CN=Imla Release" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
P12_PASSWORD="$(openssl rand -base64 24)"
# -legacy: macOS's `security import` rejects OpenSSL 3's default PKCS#12 encryption.
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "Imla Release" \
    -passout "pass:$P12_PASSWORD" -out cert.p12
CERT_SHA1="$(openssl x509 -in cert.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"

# Sparkle EdDSA key: Sparkle stores the 32-byte seed and the 32-byte public key, each base64.
openssl genpkey -algorithm ed25519 -out ed.pem
SPARKLE_PRIVATE="$(openssl pkey -in ed.pem -outform DER | tail -c 32 | base64)"
SPARKLE_PUBLIC="$(openssl pkey -in ed.pem -pubout -outform DER | tail -c 32 | base64)"

bw get template item | jq \
    --arg name "$ITEM" \
    --arg notes "$(base64 < cert.p12 | tr -d '\n')" \
    --arg p12pw "$P12_PASSWORD" --arg sha1 "$CERT_SHA1" \
    --arg edpriv "$SPARKLE_PRIVATE" --arg edpub "$SPARKLE_PUBLIC" \
    '.type = 2 | .secureNote = {type: 0} | .name = $name | .notes = $notes | .login = null
     | .fields = [
         {name: "p12 password", value: $p12pw, type: 1},
         {name: "certificate sha1", value: $sha1, type: 0},
         {name: "sparkle private key", value: $edpriv, type: 1},
         {name: "sparkle public key", value: $edpub, type: 0}]' \
    | bw encode | bw create item >/dev/null
bw sync >/dev/null

echo "Stored \"$ITEM\" in Bitwarden."
echo "Certificate SHA-1:  $CERT_SHA1"
echo "Sparkle public key: $SPARKLE_PUBLIC   (goes in Resources/Info.plist as SUPublicEDKey)"
