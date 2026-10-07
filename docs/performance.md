Performance/API audit, 2026-09-23. Checked with the installed Swift 6.4 compiler
and macOS 27 SDK, retaining the app's macOS 15 deployment target.

The existing AppKit status item, serial sampling queues, coalesced Dispatch timers,
and native counters are appropriate for this one-second monitor. Release already
enables Swift whole-module compilation. There are no third-party dependencies to upgrade.

Changes made:

| Area | Finding and change |
| --- | --- |
| Process enumeration | `proc_listallpids` returns a PID count, not bytes. Dividing again by `sizeof(pid_t)` discarded roughly three quarters of the list. Use the count directly, reuse the buffer, and retry when full. |
| Process CPU cost | Request only `RUSAGE_INFO_V0`, keep the top ten candidates, and look up only their names. Reuse baseline dictionaries. Previously every accessible process got a name lookup and the whole list was sorted. |
| CPU correctness | Compare Mach tick deltas directly to elapsed Mach ticks, avoiding cumulative time-conversion overflow. Track process start time to distinguish reused PIDs. Reset baselines when reopening the menu. |
| Interface sampling | Fetch into the existing route buffer first. Steady-state sampling uses one `sysctl` instead of a size query plus a fetch. Preserve growth retries and validate route-message boundaries, including shorter address messages. |
| Hidden status item | Disarm the timer while occluded. Previously it still woke every second to return immediately. Retain timer leeway and the unchanged-text redraw check. |
| Menu lifecycle | Capture the subscription for each session, removing a main/proc queue race. Reject stale results after close/reopen. Permit only one network query in flight, and show CPU results independently of network completions. |
| UI work | Avoid setting unchanged menu labels/colors. Construct AppKit text attributes on the main queue. Retain and remove the occlusion observer. |
| API cleanup | Use Swift `@main` and replace deprecated `kIOMasterPortDefault` with `kIOMainPortDefault` in the unused GPU helper. |

Apple's [libproc implementation](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)
confirms the PID-count contract. Its [resource accounting implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c)
shows that newer rusage flavors collect additional accounting data. V0 supplies all
the fields this feature needs and avoids that extra work; requesting the newest
flavor solely because it is newer would be counterproductive.
[Dispatch timer leeway](https://developer.apple.com/documentation/dispatch/dispatchsourcetimer/schedule(deadline:repeating:leeway:)-hvhp)
remains supported for timer coalescing. The IOKit replacement is
[`kIOMainPortDefault`](https://developer.apple.com/documentation/iokit/kiomainportdefault).

Local measurement: five alternating runs of 100 optimized full-process samples,
after one warmup sample per run, on an active Apple Silicon Mac with approximately
1,020 processes. Median wall time per sample was **1.345 ms before, 0.770 ms after**,
about **43% lower**. The before version had only the PID-count bug corrected so both
versions scanned the full list. These are process-sampler timings while the menu
is open, not a measurement of total application CPU usage or battery savings.
Shorter comparisons on the same active host showed about 32–38% reductions.

Validation completed:

- Deterministic regression tests for PID enumeration/growth, top-ten selection,
  CPU units and long-lived counters, PID reuse, menu baseline reset, interface
  churn/counter resets, loopback exclusion, short/malformed route messages,
  overlapping network queries, and stale completions after stop/restart.
- Optimized compilation and linking of the actual Swift/Objective-C app sources,
  with warnings treated as errors and the macOS 15 minimum target.
- Live single-process CPU load measured 99.6%, consistent with one busy core.
- Live status totals, CPU/network menu callbacks, and 20 rapid close/reopen cycles.
  The menu smoke test also passed under Thread Sanitizer without reported races.

Run `bash tests/run.sh` for deterministic checks and compilation. Run
`RUN_LIVE=1 bash tests/run.sh` for the optional live checks; these briefly add a
status item and require a logged-in GUI session and a working network-statistics backend.
The follow-up command-line build uses programmatic startup and `iconutil`, removing
the requirement for Xcode's nib and asset compilers. `bash build.sh` produces an
optimized, locally signed `build/menustat.app`; the Xcode project remains usable.
The bundle passed signature verification and finished launching from that exact
build path as a menu-bar-only application, using Command Line Tools alone.

Remaining constraints: per-process networking still uses the private
`NetworkStatistics` framework. It worked on this machine, but Apple provides no
public compatibility contract for its dynamically resolved symbols or dictionary
keys. Failure to load now displays “Unavailable.”
[`NWConnection`](https://developer.apple.com/documentation/network/nwconnection)
is an API for connections owned by the caller; it does not replace this system-wide
view. Moving to a supported Network Extension design would be separate work.
The E/P cluster split retains the existing assumption about processor ordering.
`GPUInfo.m` is not part of the app target; its experimental driver selector is not
validated or enabled by this audit.
