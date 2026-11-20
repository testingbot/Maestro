#!/usr/bin/env bash
set -euo pipefail

# Re-signs the PUBLISHED physical-iOS driver zips for a new provisioning profile and
# puts them back on the asset mirror, so a newly registered device can run Maestro.
# Called by hypervisor scripts/realios/add-device.sh after it regenerates the profile.
#
# Usage:
#   ./maestro-ios-xctest-runner/publish-resigned-drivers.sh <mobileprovision> [signing-identity]
#
# For each variant (ios18, ios26) it:
#   1. downloads $MIRROR_URL/maestro-iphoneos-driver-build-<variant>.zip
#   2. skips it when its runner already embeds this profile (re-runs are no-ops)
#   3. re-signs it with resign-maestro-ios-runner.sh in a scratch MAESTRO_HOME
#      and checks every UDID of the profile is in the embedded copy
#   4. uploads it to $PUBLISH_HOST:$PUBLISH_DIR, keeps the old one as
#      <name>-prev-<YYYYMMDD>.zip and swaps the new one in with one mv (a guest
#      downloading at that moment gets either the old or the new zip, never half)
# Then it sets the IOS_PROVISIONING_PROFILE_BASE64 secret on $GITHUB_REPO, so the
# next "Build Physical iOS Drivers" run signs for the same devices.
#
# Guests cache the driver keyed on the mirror's ETag (vm scripts/maestro-ios.sh),
# so they fetch the new zip at their next Maestro session.
#
# Env:
#   MIRROR_URL    default http://192.168.168.16:6003/maestro
#   PUBLISH_HOST  default root@192.168.168.16 (worker01)
#   PUBLISH_DIR   default /apps/updater/current/maestro
#   GITHUB_REPO   default testingbot/Maestro (SKIP_SECRET=1 to leave the secret alone)
#   PUBLISH=0     re-sign and check only; leave the mirror and the secret untouched
#
# The R2 mirror of the updater tree (s3://browsers/updater/maestro/) is synced by
# hand; the script prints a reminder.

PROFILE="${1:?Usage: $0 <mobileprovision> [signing-identity]}"
IDENTITY="${2:-3565EDAFEE1BED3AE2A012CF0A8F5FEE798C46A2}"
MIRROR_URL="${MIRROR_URL:-http://192.168.168.16:6003/maestro}"
PUBLISH_HOST="${PUBLISH_HOST:-root@192.168.168.16}"
PUBLISH_DIR="${PUBLISH_DIR:-/apps/updater/current/maestro}"
GITHUB_REPO="${GITHUB_REPO:-testingbot/Maestro}"
PUBLISH="${PUBLISH:-1}"
VARIANTS="ios18 ios26"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESIGN="$SCRIPT_DIR/resign-maestro-ios-runner.sh"
RUNNER_PROFILE='maestro-iphoneos-driver-build/driver-iphoneos/Build/Products/Debug-iphoneos/maestro-driver-iosUITests-Runner.app/embedded.mobileprovision'

log() { printf '\033[1;34m[maestro-driver]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[maestro-driver]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$PROFILE" ] || die "profile not found: $PROFILE"
[ -x "$RESIGN" ] || die "$RESIGN missing"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

profile_field() { security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null; }
profile_udids() { security cms -D -i "$1" 2>/dev/null | plutil -extract ProvisionedDevices json -o - - | tr -d '[]"' | tr ',' '\n' | sort; }

NEW_UUID=$(profile_field "$PROFILE" UUID)
[ -n "$NEW_UUID" ] || die "cannot read the UUID of $PROFILE"
profile_udids "$PROFILE" > "$WORK/want.txt"
log "profile $NEW_UUID ($(wc -l < "$WORK/want.txt" | tr -d ' ') devices)"

STAMP=$(date +%Y%m%d)
CHANGED=0
for v in $VARIANTS; do
	name="maestro-iphoneos-driver-build-$v.zip"
	log "$v: downloading $MIRROR_URL/$name"
	curl --fail --silent --show-error -o "$WORK/$v.zip" "$MIRROR_URL/$name"

	unzip -p "$WORK/$v.zip" "$RUNNER_PROFILE" > "$WORK/$v-old.mobileprovision"
	old_uuid=$(profile_field "$WORK/$v-old.mobileprovision" UUID || true)
	if [ "$old_uuid" = "$NEW_UUID" ]; then
		log "$v: already signed with $NEW_UUID, skipping"
		continue
	fi
	log "$v: re-signing (was ${old_uuid:-unknown})"

	home="$WORK/home-$v"
	mkdir -p "$home"
	unzip -q "$WORK/$v.zip" -d "$home"
	MAESTRO_HOME="$home" DRIVER_VARIANT="$v" "$RESIGN" "$PROFILE" "$IDENTITY" > "$WORK/$v-resign.log" 2>&1 \
		|| { cat "$WORK/$v-resign.log" >&2; die "$v: re-signing failed"; }
	out="$home/$name"

	# Same files as the published zip, and the runner really embeds the new profile.
	diff <(unzip -Z1 "$WORK/$v.zip" | sort) <(unzip -Z1 "$out" | sort) > /dev/null \
		|| die "$v: re-signed zip lists different files than the published one"
	unzip -p "$out" "$RUNNER_PROFILE" > "$WORK/$v-new.mobileprovision"
	[ "$(profile_field "$WORK/$v-new.mobileprovision" UUID)" = "$NEW_UUID" ] || die "$v: runner does not embed $NEW_UUID"
	profile_udids "$WORK/$v-new.mobileprovision" | cmp -s - "$WORK/want.txt" || die "$v: embedded device list differs from the profile"

	if [ "$PUBLISH" != "1" ]; then
		cp "$out" "./$name"
		log "$v: PUBLISH=0, left the re-signed zip at ./$name"
		continue
	fi

	sum=$(shasum -a 256 "$out" | cut -c1-64)
	scp -q "$out" "$PUBLISH_HOST:$PUBLISH_DIR/.upload-$name"
	# shellcheck disable=SC2029  # expanded locally on purpose
	ssh "$PUBLISH_HOST" "set -e; cd '$PUBLISH_DIR'
		[ \"\$(sha256sum '.upload-$name' | cut -c1-64)\" = '$sum' ] || { echo 'checksum mismatch after upload' >&2; exit 1; }
		[ -e '${name%.zip}-prev-$STAMP.zip' ] || cp -p '$name' '${name%.zip}-prev-$STAMP.zip'
		chmod 644 '.upload-$name'
		mv '.upload-$name' '$name'"
	etag=$(curl --silent --head "$MIRROR_URL/$name" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
	log "$v: published (old kept as ${name%.zip}-prev-$STAMP.zip, ETag $etag)"
	CHANGED=1
done

if [ "$PUBLISH" = "1" ] && [ "${SKIP_SECRET:-0}" != "1" ]; then
	base64 -i "$PROFILE" | gh secret set IOS_PROVISIONING_PROFILE_BASE64 -R "$GITHUB_REPO"
	log "set IOS_PROVISIONING_PROFILE_BASE64 on $GITHUB_REPO"
fi

if [ "$CHANGED" = "1" ]; then
	log "R2 is synced by hand: copy the new zips from $PUBLISH_HOST:$PUBLISH_DIR to s3://browsers/updater/maestro/"
fi
