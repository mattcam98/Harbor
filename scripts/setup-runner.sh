#!/usr/bin/env bash
# The entry point inside the Harbor Setup download (scripts/package-setup-mac.sh
# copies this in as "install-harbor"). The download page's install line runs
# it; it can also be run by hand from the unpacked folder.
#
#   install-harbor [--apple-id you@example.com] [--udid ID] [--ipad]
#
# Checks Harbor.ipa against the digest packaged beside it, asks Apple whether
# it accepts sign-in from this Mac, then signs in, signs Harbor with your
# Apple ID, installs it on the connected iPhone and gives it a pairing file
# and its signing certificate. The password is used once to sign in to Apple
# and is not stored or sent anywhere else. Run it again within seven days to
# renew from the Mac; Harbor can also renew itself from the phone.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

"$here/harbor-setup" verify "$here/Harbor.ipa" --sha256 "$(cat "$here/Harbor.ipa.sha256")"
"$here/harbor-setup-mac" check
exec "$here/harbor-setup-mac" install --ipa "$here/Harbor.ipa" --tool "$here/harbor-setup" "$@"
