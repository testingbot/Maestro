@AGENTS.md

# TestingBot fork (tb-mods)

This is TestingBot's fork of Maestro, rebased on upstream v2.12.1. The fork's main addition is support for physical iOS devices, which upstream does not offer (upstream #3609 rejects connected iPhones; this fork reverts that). Fork versions end in `-tb`.

## iOS Physical Device Driver

The pre-built XCTest runner (`maestro-driver-iosUITests-Runner.app`) is signed with a Development provisioning profile. Every physical test device UDID must be registered in the profile or install fails with `0xe8008012`.

When adding a new device, hypervisor `scripts/realios/add-device.sh` does all of it: it registers the UDID, regenerates the profile and runs `./maestro-ios-xctest-runner/publish-resigned-drivers.sh <profile>`. That script downloads the published `maestro-iphoneos-driver-build-{ios18,ios26}.zip` from the asset mirror (`http://192.168.168.16:6003/maestro`, worker01 `/apps/updater/current/maestro`), re-signs them with `resign-maestro-ios-runner.sh` (`MAESTRO_HOME` points it at a scratch dir), swaps them in (old kept as `*-prev-<date>.zip`) and updates the `IOS_PROVISIONING_PROFILE_BASE64` secret for CI. Guests re-download on the ETag change. The R2 copy (`s3://browsers/updater/maestro/`) is synced by hand.

Key code: `LocalIOSDeviceController.kt` (install/launch via `xcrun devicectl`), `LocalXCTestInstaller.kt` (orchestration), `IOSBuildProductsExtractor.kt` (bundle extraction).

## Debug Logs

- CLI logs: `~/.maestro/tests/*/maestro.log`
- iOS XCTest logs: `~/Library/Logs/maestro/xctest_runner_logs`

