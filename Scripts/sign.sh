#!/bin/sh
# Shared code signing helper.
#
# Meter reads credentials that other apps own (Cursor's WorkOS session, a browser's
# Safe Storage key). macOS records the "Always Allow" grant against the app's
# designated requirement, and an ad-hoc signature puts the binary's own hash there:
#
#   ad-hoc      => cdhash H"97720ab1..."          changes on every rebuild
#   certificate => identifier "com.justn.meter" and certificate leaf[subject.CN] = ...
#
# So an ad-hoc build revokes its own keychain access every time it is rebuilt.
# Signing with a certificate keeps the requirement stable, which keeps the grant.
# An Apple Development certificate is enough and comes with a free Apple ID;
# notarization is only needed to distribute the app to other Macs.

meter_signing_identity() {
    if [ -n "${METER_SIGN_IDENTITY:-}" ]; then
        echo "$METER_SIGN_IDENTITY"
        return 0
    fi
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ { print $2; exit }'
}

meter_signing_identity_fallback() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ { print $2; exit }'
}

meter_sign() {
    target=$1
    identity=$(meter_signing_identity)
    [ -n "$identity" ] || identity=$(meter_signing_identity_fallback)

    if [ -z "$identity" ]; then
        echo "warning: no code signing certificate found, falling back to ad-hoc." >&2
        echo "warning: keychain access grants will reset on every rebuild." >&2
        echo "warning: set METER_SIGN_IDENTITY to a certificate name to fix this." >&2
        identity=-
    fi

    codesign --force --sign "$identity" "$target"
    codesign --verify --strict --verbose=2 "$target"
    echo "signed '$(basename "$target")' with: $identity" >&2
}
