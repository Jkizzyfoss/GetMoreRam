# PIPELINE

## Codebase
- `GetMoreRam/` — SwiftUI iOS app (`GetMoreRam.xcodeproj`, scheme `GetMoreRam`).
  - `LoginViewModel.swift` — Apple ID sign-in via SideSign `DeveloperPortal`; 2FA handler; maps the result back to StosSign types for the signing UI.
  - `Shared.swift` — `AnisetteClientInfo` (Windows identity), `AnisetteDefaults`/`AnisetteSettings`, `AnisetteProviderState`, `AnisetteRecovery`, `AnisetteSettingsMigrator`, `SharedModel`.
  - `AnisetteDataHelper.swift` — remote v3 anisette (provisioning over WebSocket, `/v3/get_headers`, 429/503 retry, ephemeral session).
  - `OnDeviceAnisetteHelper.swift` — on-device ODA path and remote→SideSign conversion.
  - `SettingsView.swift` — account, anisette toggles/server, clean-up, import SideStore account.
  - `AppID*.swift`, `SideStoreAccount.swift`, `Keychain.swift` — App ID/capability flow, account import, Keychain.
- `ThirdParty/StosSign/` — local StosSign package, used only for the App ID/signing API and models.
- `OpenSSL` — git submodule.
- Remote SwiftPM: `SideSign` pinned to `Mr3242-Scripter/SideSign@ac3df50c` (upstream `752d1ef6` + Windows GSA/2FA fix from SideStore PR #1683), plus `AnisetteKit`, `CodeSignKit`, `GSACryptoKit`, `libdeflate`.
- Graphify graph: none in this repo.
- CI: `.github/workflows/build.yml` (macOS build + analyze + archive, fake-sign IPA, nightly release).

## Feature: Apple ID -80046 / Windows Anisette fix (branch `fix/apple-id-80046-windows-anisette`)

### Plan
Sign in as a Windows PC against a Windows-ADI v3 server: Windows client-info + `akd/1.0 CFNetwork/808.1.4`, updated GrandSlam headers, ephemeral session, 429/503 backoff, 2FA Mac fallback, and stale `adi.pb` recovery. Keep both the on-device and remote providers working.

### Code as written (commit `76aa36e`)
- Single SideSign `DeveloperPortal.authenticate` path for both providers; StosSign login flow retired.
- Windows identity defaults, new default server `ani.jkcoxson.com`, on-device default off, one-time `UserDefaults` migration.
- SideSign pinned to the fork revision containing the GSA/2FA changes.

### Review round (this pass)
Issues found and fixed:
1. `AnisetteDataHelper` trusted each server's `/v3/client_info`; the "Windows ADI" servers still advertise a MacBook profile, so the app would announce a Mac identity again. Now always reports the Windows profile.
2. No recovery from an identity Apple refuses. Added `AnisetteRecovery` (purge `adi.pb` + identifier + caches) and a one-shot purge-and-retry in `LoginViewModel.signIn`. Purge is limited to `-80045`/`-80046`, `DeveloperPortalError.invalidAnisetteData`, HTTP `433`/`503`, and `not provisioned`; network/credential/cancel errors keep the identity.
3. Retry left `isVerificationCodeSubmitting` set, which disabled the 2FA field on the second attempt.
4. User cancellation surfacing from SideSign as a normal error is now re-thrown as `CancellationError` so no alert is shown.
5. Settings/README copy corrected (server list, client-info behaviour, known limits).

### Open
- Needs a real build (CI) and on-device live sign-in / 2FA / team selection / App ID signing verification.
- Repoint `SideSign` to upstream once PR #1683 lands.
