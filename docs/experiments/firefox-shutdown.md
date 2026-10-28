# Firefox shutdown and installation locks

The ownership witness requires an unchanged pinned browser installation after
every page. A normal Firefox exit can still leave an installation lock. Both
Firefox launchers request `toolkit.shutdown.fastShutdownStage=0` so final
destructors run. WebGL settings, source and runtime hashes, page watchdogs,
process watchdogs and job deadlines remain part of qualification.

## Observed failure

After PR #222 passed all 26 checks, merged main failed Firefox 4.3's second
negative partition. [Job 121851461554](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/40402422670/job/121851461554)
rejected `firefox_installation/firefox/lock` after the ready-pressure page.
Artifact 12689643715 records normal exit with code zero and no signal.
Closing owned contexts first did not eliminate this failure.

The historical Firefox 142 source used Playwright's base commit
`361373160356d92cb5cd4d67783a3806c776ee78` with its reviewed patch set.
[AppShutdown.cpp](https://raw.githubusercontent.com/mozilla-firefox/firefox/361373160356d92cb5cd4d67783a3806c776ee78/xpcom/base/AppShutdown.cpp)
uses `_exit` during fast shutdown. This skips the final static destructor in
[nsProfileLock.cpp](https://raw.githubusercontent.com/mozilla-firefox/firefox/361373160356d92cb5cd4d67783a3806c776ee78/toolkit/profile/nsProfileLock.cpp)
that removes remaining lock symlinks.

[UpdateService.sys.mjs](https://raw.githubusercontent.com/mozilla-firefox/firefox/361373160356d92cb5cd4d67783a3806c776ee78/toolkit/mozapps/update/UpdateService.sys.mjs)
releases the updater mutex on `quit-application`. An asynchronous background
check can later call `hasUpdateMutex()` after awaiting URL formatting.
That path can acquire the mutex again after its quit observer was removed.
The exact asynchronous trigger in the failed CI process remains inferred.

## Paired regression control

The [control](../../scripts/reference/firefox_shutdown_control.py) copies only
the already verified Firefox installation into two independent owned directories.
It uses Marionette only in these isolated processes to install a late shutdown
observer. Gameplay and ownership pages retain their existing Playwright protocol.
Firefox 157's pinned Playwright build omits the updater XPCOM component and its
`UpdateService.sys.mjs`; the historical updater-specific injection is unavailable.
The control now creates a named profile object inside the process's isolated
profile, redirects that object's root to the owned runtime copy, and calls its
real native `lock()` at `profile-before-change`. It retains the resulting native
lock until process teardown. This exercises the same `nsProfileLock` lifetime
without assuming an updater service exists. The observer checks the actual
preference, records an initially absent lock, and proves a real lock was acquired.
No lock symlink is synthesized or deleted by the control.

With actual shutdown stage `1`, the browser exits zero and adds only its own
installation lock symlink. The original inventory guard must reject it.
With stage `0`, the same late native-lock acquisition occurs and the browser exits zero;
the complete runtime inventory must equal its original snapshot exactly.
The control never deletes the lock, excludes an entry, or rewrites runtime files.

The initial updater-specific ARM control demonstrated this pair on Firefox 142.0.1.
The two original inventories each contained 47 regular files. Stage `1` added
the lock; stage `0` preserved every file hash and added nothing.
The replacement native-profile control demonstrates the same pair on Firefox 157.0.
This establishes the native lock cleanup contract, not the presence of an updater
or the precise timing of the historical CI updater task.

Automation can override profile preferences during initialization. The control
sets the preference after Marionette starts and reads it back before quit and
inside the late observer. Earlier profile-only comparisons actually ran stage
`3`; they do not establish a stage `0` result.

Run against an installation already verified from the pinned archive:

```sh
python3 scripts/reference/firefox_shutdown_control.py \
  --firefox .cache/reference/ownership-firefox/x86_64/firefox/firefox \
  --work-dir .cache/scratch/firefox-shutdown-control \
  --output .cache/reference/results/firefox-shutdown-control
```

Both directories must be fresh and separate. Browser copies and profiles stay
in the work directory. Retain both process logs, inventories and
the paired receipt, including the deliberately rejected fast-shutdown process.
This control alone does not prove archive provenance or qualify the broader
browser release matrix. Full ownership qualification still needs both engines,
phases and suite partitions with exact native/browser comparisons.

## Firefox 157 upgrade regression

The first upgraded CI ownership job completed its native/Web suite, then failed
because `@mozilla.org/updates/update-mutex;1` was undefined. The actual pinned ARM
browser reproduces that exact Marionette error. Error responses now retain a
bounded ASCII-escaped diagnostic, so an unavailable browser interface is visible.

The replacement control passes on the same pinned browser: stage `1` exits zero
and leaves only its own installation lock, which the unchanged runtime guard
rejects; stage `0` exits zero and preserves the complete original inventory.
It keeps both cleanup and the negative guard control rather than skipping the
probe or accepting a changed installation.
