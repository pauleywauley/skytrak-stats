# SkyTrak Stats

An unofficial Mac companion for the SkyTrak golf simulator. SkyTrak stays on your projector while this app fills a second monitor with a live shot map, every stat for each shot, and a browsable shot history.

Not affiliated with or endorsed by SkyTrak or GOLFTEC.

## Install

1. Download `SkyTrakStats.zip` from the [latest release](https://github.com/pauleywauley/skytrak-stats/releases/latest), then double-click it to unzip.
2. Double-click **SkyTrak Stats**. macOS will refuse the first time because the app isn't signed with a paid Apple certificate.
3. Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway**.

The app then installs itself into Applications and reopens. It needs macOS 12 or later and runs on Intel and Apple Silicon.

## Using it

Run it on the same Mac as SkyTrak. With two or more displays it fills the right-most one. **Move Screen**, **Full Screen** and **Quit** are in the menu at the top right.

- **Shot Shape / Dispersion** switches the map view. **Clear** starts a fresh map without deleting any history.
- The green club button picks the club for upcoming shots, because SkyTrak doesn't write its selected club anywhere readable until it syncs. **Change** fixes the club on any single shot.
- **Smash Factor** leads the screen, with the impact numbers around it. **Hide Details** removes the bottom strip.
- **Launch Angle, Back Spin and Descent Angle** turn green, orange or red using SkyTrak's own targets for the club and club speed, read from your installed copy of SkyTrak. They need a club to be set.
- **History** lists every session, with averages by club. Click a shot to reopen it.

## Where the numbers come from

The app only reads SkyTrak's log files. It doesn't modify SkyTrak or send your data anywhere, and its only network use is checking GitHub for updates.

| Available | Numbers |
| --- | --- |
| About 2 seconds after impact | Ball speed, launch, side angle, spin, spin axis, club speed |
| When the ball stops | Attack angle (SkyTrak's rough estimate), final club speed |
| Calculated live, marked `EST` | Carry, total, roll, offline, max height, descent, flight time, club path, face angles |
| After SkyTrak's cloud sync (at launch and around midnight) | SkyTrak's official values and club name, which replace the estimates |

Estimates assume flat ground. SkyTrak adjusts for course terrain, so live numbers on a hilly hole can differ until its official values arrive.

## Updating

When a new version is out, an update button appears in the top bar. Every push to `main` builds and publishes one automatically.

To build locally, install the Xcode Command Line Tools and run `scripts/build.sh`.
