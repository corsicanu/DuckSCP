# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by build_app.sh and package.sh (after branding.env): picks the signing identity.
# Order: SIGN_IDENTITY_OVERRIDE, then branding.env's SIGN_IDENTITY, else ad hoc ("-") when
# that identity is not in the keychain.
SIGN_IDENTITY="${SIGN_IDENTITY_OVERRIDE:-${SIGN_IDENTITY:--}}"
if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  echo "warning: signing identity \"$SIGN_IDENTITY\" not found; signing ad hoc (Keychain will ask again after updates)" >&2
  SIGN_IDENTITY="-"
fi
