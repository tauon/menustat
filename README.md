# menustat

A small macOS menu bar app for keeping an eye on CPU and network activity.

![menustat screenshot](docs/screenshot.png)

Build and run with Apple's Command Line Tools; the Xcode app is optional:

```sh
bash build.sh
open build/menustat.app
```

The script produces an optimized app for this Mac's architecture, with a local
ad-hoc signature and a macOS 15 minimum. Quit an already-running copy before
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
