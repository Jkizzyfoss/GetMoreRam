# Get More Ram
A simple [StosSign](https://github.com/stossy11/StosSign) wrapper app that allows you to enable "Increased Memory Limit" for your sideloaded apps without using Xcode.
This fork is using the local anisette server from SideStore with the android client fix.

# How to use
1. Sideload this app
2. Go to settings, sign in your account that you used to sign the app you want to enable "Increased Memory Limit"
3. Go to "App IDs" page
4. Tap Refresh
5. Tap the app you want to enable "Increased Memory Limit"
6. Tap "Add Increased Memory Limit"
7. Reinstall the app from SideStore/AltStore
8. Check if you have "Increased Memory Limit"

# Apple ID sign-in fix (`-80045` / `-80046`)

Since roughly mid-October 2026 Apple's GrandSlam endpoint answers Mac / Android /
Xcode anisette identities with HTTP `503`, which surfaces in the app as error
`-80045` / `-80046` (see [SideStore#1652](https://github.com/SideStore/SideStore/issues/1652#issuecomment-6184782138)
and [SideStore#1686](https://github.com/SideStore/SideStore/issues/1686)). The
workaround is to sign in as a **Windows PC** using anisette data served by a v3
server that actually mints Windows identities.

What this fork now does:

- Every sign-in — whether the on-device Anisette toggle is on or off — goes through
  the same SideSign `DeveloperPortal` authentication path, so the older StosSign
  login flow (and its Mac identity) is no longer used for the remote configuration.
- The remote path queries the configured server's `/v3/client_info` and reports that
  same profile to GrandSlam, so the anisette headers and the authentication payload
  never disagree. Only Windows-compatible profiles are accepted; anything else falls
  back to the built-in Windows profile.
- Default Anisette server is `https://ani.jkcoxson.com`; the on-device toggle now
  defaults to **off**. `https://ani2.stikstore.app` is a known alternative. The
  server URL stays editable in Settings.
- Existing installs are migrated once (`AnisetteSettingsMigrator`): the legacy
  `https://ani.sidestore.io` server and the legacy Mac client-info string are
  replaced, while an explicit user choice (a custom server, or a manually toggled
  on-device switch) is preserved.
- Switching Anisette server or provider requests a fresh identity/`adi.pb`.
  Credentials and identities are never wiped for ordinary network errors — only for
  a confirmed unprovisioned error (`-45061`) or a provider switch.

The GrandSlam/2FA changes themselves (Windows headers, ephemeral session without
connection reuse, `429`/`503` backoff, trusted-device + SMS 2FA and the Mac fallback
for Apple's 2FA endpoints when the Windows identity gets a `403`) live in the
SideSign dependency. This fork pins `SideSign` to the revision that contains them
(see `project.pbxproj` / `Package.resolved`).

## Remaining limitations

- The SideSign revision is pinned to a fork (`Mr3242-Scripter/SideSign`, the fix
  attached to the still-open [SideStore PR #1683](https://github.com/SideStore/SideStore/pull/1683))
  rather than to the upstream `SideStore/SideSign` repo. Once the fix lands upstream,
  the dependency should be repointed to `SideStore/SideSign`.
- Not all accounts succeed even with Windows anisette; some still get `-80045`.
- SMS 2FA has been unreliable against Apple's endpoints; trusted-device verification
  is the reliable path.
- This change was authored on Linux, so it has **not** been compiled with Xcode or
  exercised against live Apple authentication. Live sign-in, 2FA and the follow-up
  signing/install flow still need to be verified on a device.

# Credits
Stossy11 - For StosSign.
SideStore - Anisette Data fetching codes are stolen from SideStore
Mr3242-Scripter - SideSign Windows GSA fix used by the authentication workaround
