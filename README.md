# Vibe — native iPhone app (sideload kit)

The `ios/` folder is a REAL native iOS app (Capacitor): a native casing whose
webview runs the live site, with native permissions (camera, mic, photos,
location, contacts) already declared, the Vibe icon, dark splash, and native
status-bar/keyboard behaviour. iPhones can't run a raw .app from Windows, so
the pipeline is:

    push to GitHub  →  GitHub's macOS machine compiles Vibe-unsigned.ipa
                    →  download it on the PC
                    →  Sideloadly signs it with your Apple ID + installs over USB

## One-time setup (~10 minutes)

1. **Put this repo on GitHub** (private). On the PC:

       git remote add origin https://github.com/<your-user>/vibe.git
       git push -u origin main

2. **Run the build**: GitHub → the repo → Actions → "Build iOS app (unsigned
   IPA)" → Run workflow. ~10 minutes later, download the `Vibe-unsigned-ipa`
   artifact (it's a zip containing `Vibe-unsigned.ipa`).

3. **Install Sideloadly** on the PC from https://sideloadly.io (Windows
   version). It signs IPAs with a normal Apple ID and pushes them over USB.

4. **Phone**: plug the iPhone in with a cable → open Sideloadly → drag
   `Vibe-unsigned.ipa` in → enter the Apple ID → Start. First time only:
   iPhone Settings → General → VPN & Device Management → trust the developer
   profile. The Vibe icon appears on the home screen.

## Honest limits of a FREE Apple ID

- The install expires after **7 days** — re-run Sideloadly weekly (same cable,
  two clicks). A paid Apple Developer account ($99/yr) makes it 1 year and
  unlocks TestFlight (send the app to testers by link) and push notifications.
- **Push notifications don't work** with a free ID (Apple restriction).
  Everything else does: camera, mic (calls!), photo library, location, haptics.

## Updating the app

The casing loads the live site, so **normal Vibe deploys update the app
instantly — no rebuild, no reinstall**. Only changes to the casing itself
(new native plugin, icon, permissions) need a new IPA: edit `native/`, push,
re-download, re-sideload.

## Android later

`npx cap add android` in this folder + an ubuntu build job gives an APK that
installs directly, no signing hoops, no 7-day expiry. Say the word.
