#!/bin/zsh
# Backs up Nocturne's Sparkle EdDSA update-signing key (keychain account "nocturne")
# into an AES-256 encrypted disk image, copied to iCloud Drive and ~/Documents.
# You choose the image password interactively; the plaintext key only ever exists
# in a private temporary folder that is removed afterwards.
#
# Restore on a new Mac (after mounting the image with your password):
#   build/DDR/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account nocturne -f "/Volumes/Nocturne Sparkle Key/nocturne-sparkle-private-key.txt"
set -euo pipefail
cd "$(dirname $0)/.."

tools=$(dirname "$(find build -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1)")
[[ -x $tools/generate_keys ]] || { print -u2 "Sparkle tools not found; build the project once first."; exit 1; }
public=$("$tools/generate_keys" --account nocturne -p)

stamp=$(date +%Y-%m-%d)
image="Nocturne-Sparkle-Key-$stamp.dmg"
icloud="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Nocturne Backups"
local_copy="$HOME/Documents/Nocturne Backups"

work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
mkdir "$work/payload"

"$tools/generate_keys" --account nocturne -x "$work/payload/nocturne-sparkle-private-key.txt"
cat > "$work/payload/README.txt" <<EOF
Nocturne — Sparkle EdDSA update-signing key
Backed up: $stamp
Keychain account: nocturne
Public key (must match SUPublicEDKey in project.yml): $public

Restore:
  generate_keys --account nocturne -f nocturne-sparkle-private-key.txt
(generate_keys ships with Sparkle: build/DDR/SourcePackages/artifacts/sparkle/Sparkle/bin/)

Anyone with this key can sign updates that installed copies of Nocturne will accept.
Keep this image and its password private.
EOF

print "Choose a password for the encrypted backup image (store it in the Passwords app)."
hdiutil create -quiet -encryption AES-256 -fs APFS -volname "Nocturne Sparkle Key" \
  -srcfolder "$work/payload" "$work/$image"

mkdir -p "$icloud" "$local_copy"
cp "$work/$image" "$icloud/$image"
cp "$work/$image" "$local_copy/$image"
print "Encrypted backup saved to:"
print "  $icloud/$image"
print "  $local_copy/$image"
hdiutil imageinfo "$local_copy/$image" | grep -E "Encrypted|Format:" || true
