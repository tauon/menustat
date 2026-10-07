# menustat

A small macOS menu bar app for keeping an eye on CPU and network activity.

The dropdown also shows GPU utilization and used / physical memory in GiB below
Cores and Net. Memory includes app, wired, and compressed pages, excluding
reclaimable cache. On multi-GPU Macs the busiest GPU is shown; drivers without
utilization counters show Unavailable. These metrics sample once per second only
while the dropdown is open, using its existing timer and releasing their kernel
handles when it closes.

![menustat screenshot](docs/screenshot.png)

Build and run with Apple's Command Line Tools; the Xcode app is optional:

```sh
bash build.sh
open build/menustat.app
```

The script produces an optimized app for this Mac's architecture, with a local
ad-hoc signature and a macOS 27 minimum. Set `MENUSTAT_SIGN_IDENTITY` to an installed
Apple signing identity for a stable helper identity across builds. Quit an already-running copy before
launching the new build. You can also build the project with Xcode.

Run sampling regression tests and an optimized compile/link check with `bash tests/run.sh`.
Use `RUN_LIVE=1 bash tests/run.sh` to also exercise live CPU/network sampling and menu lifecycle
in a logged-in macOS GUI session. Leave the mouse/keyboard idle during the native
menu-tracking check; it opens the dropdown twice and checks that updates don't close it.

Network totals count Ethernet/Wi-Fi, FireWire, and cellular link traffic. VPN tunnel,
bridge, VLAN, and bond counters are excluded so the same bytes aren't counted twice.
Totals include protocol overhead and all traffic; the dropdown shows the busiest
processes' TCP/UDP traffic, so the numbers need not match exactly.
Recently active network processes remain listed for three seconds after activity
stops, showing zero rates while idle. Active processes take priority in the top five.

**Mouse Button Navigation** translates standard mouse button 4 (back) and button 5
(forward) presses based on the frontmost app:

- Safari / Safari Technology Preview: Command-[ / Command-] (back / forward).
- Finder: Command-[ / Command-] (back / forward through folder history).
- Kitty: Command-Shift-[ / Command-Shift-] (previous / next tab).

In Safari, hold Command and scroll the wheel up for the previous tab or down for
the next tab. Physical wheel direction stays the same with Natural Scrolling on.
Smooth scrolling is limited to one tab change per 150 ms; momentum does not switch
tabs. Ordinary scrolling and other apps' Command-scroll remain unchanged.

Other apps receive their normal mouse events. Each press navigates once, and the
middle button is unchanged. Kitty uses its standard tab shortcuts; custom
overrides of those shortcuts also affect this feature.

The feature defaults to enabled but waits for Accessibility permission. From the
menubar dropdown, choose **Mouse Button Navigation → Allow Accessibility…**, then
allow menustat in System Settings. Switch apps or reopen the dropdown to
activate the listener. The submenu shows whether it is ready and offers a
persistent **Enabled** toggle. There is no extra helper process or polling timer.
Keep the app at a stable path (preferably `/Applications/menustat.app`) before
granting permission. Ad-hoc signed rebuilds may need fresh permission; an Apple
signing identity set through `MENUSTAT_SIGN_IDENTITY` gives the app a stable identity.
This assumes the mouse sends standard side-button events (Quartz buttons 3/4);
vendor-specific mappings may need adjustment.

The **Fan Control** submenu above Quit offers **Auto**, **Medium**, and **Max**.
Auto hands control back to macOS; Medium targets the midpoint of each fan's
reported minimum/maximum RPM, and Max targets its reported maximum. The submenu
shows External when another app controls the fans. Avoid using two fan controllers
at once. Fanless Macs and unsupported SMC layouts show Unavailable.

Manual fan control requires one-time administrator approval in **System Settings →
General → Login Items & Extensions**. Keep the app in `/Applications` and select a
preset to register its helper through `SMAppService`. The helper accepts only the
three presets and authenticates the app's code signature. It returns to Auto on
quit, disconnection, a 10-second expired connection lease, or serious thermal pressure.
Sleep returns to Auto; presets do not persist across app restarts. The helper is
packaged by both the command-line and Xcode builds. Fan-control builds should use
an Apple development or Developer ID signature: macOS pins ad-hoc helpers to a
specific build, so changing them can require fresh approval. Public distribution
of the privileged service requires Developer ID signing and notarization.

Read fan RPMs without changing settings:

```sh
/Applications/menustat.app/Contents/MacOS/menustat --fan-status
/Applications/menustat.app/Contents/MacOS/menustat --fan-service-status
```

After approving the helper, `--fan-test` runs a hardware check from Auto through
Medium and Max, verifies the measured RPMs, and restores Auto. `--fan-register`
registers the service or restarts it after installing an updated build.

Fan access uses the private AppleSMC protocol; firmware compatibility may change.
The Apple Silicon mode/unlock behavior is documented in
[macos-smc-fan's hardware research](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md).
