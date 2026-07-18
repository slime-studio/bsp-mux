# bsp-mux — a generic Build Server Protocol multiplexer

## Problem

Editors that use `sourcekit-lsp` for Swift language support discover build
settings — compiler arguments, target graphs — via the [Build Server
Protocol](https://build-server-protocol.github.io/) (BSP). `sourcekit-lsp`
finds a `buildServer.json` file in the workspace root and execs whatever it
names as `argv`, then speaks BSP JSON-RPC over that process's stdio.

When several editor windows open the same project, each one independently
launches its own copy of the BSP backend. For Xcode projects, that backend
is typically [`sourcekit-xcode-bsp`](https://github.com/tideline-studio/sourcekit-xcode-bsp),
which drives Apple's `swift-build` (the open-sourced successor to
`XCBBuildService`) to resolve the real Xcode build graph — parsing the
`.pbxproj`, resolving the package graph, computing per-target compiler
flags. That's genuinely expensive work, and today it happens once per
editor window, redundantly, with no sharing. Combined with `sourcekit-lsp`'s
own per-editor memory footprint (`sourcekitd`'s cached AST/type-checker
state, background indexing), running the same Swift project open in
multiple editors is a real source of the memory and CPU pressure reported
against `sourcekit-lsp` (see e.g.
[swiftlang/sourcekit-lsp#1541](https://github.com/swiftlang/sourcekit-lsp/issues/1541)).

## What this project does, and deliberately does not do

**In scope:** dedupe the *BSP backend* across multiple `sourcekit-lsp`
instances on the same project, so N editor windows result in exactly one
running backend process, transparently to every editor.

**Out of scope:** sharing `sourcekit-lsp`/`sourcekitd` sessions themselves.

The reason for that boundary is the load-bearing design decision behind
this whole project, so it's worth stating precisely. LSP's document
synchronization model (`textDocument/didOpen`/`didChange`/`didClose`) has no
concept of "whose edit this is" — it assumes exactly one client is the
editor-of-record for a file, and encodes that as a single ordered,
versioned mutation stream:

- There is one mutable buffer per URI at the server, not one per
  `(client, URI)` pair. Two independent clients editing the same file have
  nowhere to keep their edits separate — last write wins, and whichever
  client "loses" gets diagnostics/completions/hover answered against
  content it doesn't actually have open.
- `didChange` version numbers are a single-writer sequence; two
  uncoordinated clients can't produce a coherent shared ordering without
  something outside LSP arbitrating it.
- Capability negotiation happens once per connection; two real clients
  (different editors) will genuinely differ on markup/snippet support, so a
  shared session can only honor one of them correctly.

None of this is fixable by clever proxying — the state being shared (buffer
content) is the thing that would be wrong for whichever client didn't win.
Making LSP-layer sharing safe would require enforcing single-writer-per-file
at a broker (one "dirty" owner, others read-only, fall back to a private
server the moment two clients disagree about a file's content) — a much
harder and separate project.

BSP has none of this. It has no document synchronization at all — no
`didOpen`/`didChange` equivalent. Its state is the build graph: targets,
sources, compiler arguments, derived from disk and project configuration,
not from anyone's unsaved edits. Multiple readers asking "what are the
compiler args for this file" all get the same correct answer, because
nothing about a build graph has a "who's editing it" dimension. That's the
dividing line this project is built on: **LSP tracks client-owned mutable
state; BSP tracks shared derived facts.** Sharing the latter is just
caching; sharing the former needs a correctness model this project doesn't
attempt.

## Architecture

### Self-electing daemon

`buildServer.json`'s `argv` is exec'd fresh by each `sourcekit-lsp`
instance — there is no rendezvous built into BSP's launch mechanism (per
the [BSP spec](https://github.com/build-server-protocol/build-server-protocol/blob/master/docs/specification.md):
*"the lifetime of a build server is managed by the client... it is up to
the client to decide when to start and shut down a server"* — identical to
LSP's model, and just as unaware of multiple clients). So the same binary,
every time it's launched, either becomes the shared daemon for this project
or becomes a thin relay to an existing one:

1. Compute a deterministic **project key** from information available
   before any BSP handshake happens (workspace root, resolved backend argv,
   a small allowlist of environment variables). Derive a Unix-domain-socket
   path from it.
2. `connect()` to that socket.
   - **Succeeds** → this process is a pure byte-pump relay between its own
     stdin/stdout and the socket. No JSON-RPC parsing needed here at all —
     whatever's on the other end already does real per-connection framing.
   - **Fails** → race to become the daemon for this key.
3. **As daemon:** own the one real connection to the backend process;
   accept further client connections on the socket; cache the
   `build/initialize` handshake and replay it to each new client;
   rewrite/demux JSON-RPC request IDs; route notifications; refcount
   clients and tear down once the last one disconnects, after a short idle
   grace period.

### Wrapping the backend: `install`

There's a real chicken-and-egg problem here: the first time `bsp-mux` runs
for a project, it can't yet know the real backend's `argv`, because at that
point `buildServer.json` either still names the real backend (we haven't
taken over yet) or already names us (the real backend's argv is already
gone — overwritten, with nowhere else it was being preserved). Something
has to perform the "read the old argv, write a wrapped argv" transformation
exactly once, with the old argv in hand — that's `bsp-mux install`.

Rather than relocating the original config to a second file with its own
schema, `install` wraps the existing `argv` array **in place**, splicing
`bsp-mux` and its own flags in front, separated by the POSIX `--` convention
(the same trick `env`, `ssh ... -- cmd`, `docker run ... -- cmd` use so a
wrapper's own flags never collide with the wrapped command's):

```json
{
  "argv": ["/path/to/bsp-mux", "--workspace-root", "/abs/real/path", "--",
           "sourcekit-xcode-bsp", "serve", "--other-configs"],
  "name": "sourcekit-xcode-bsp",
  "version": "0.1.0",
  "bspVersion": "2.1.0",
  "languages": ["swift"]
}
```

Everything after `--` is the real backend's command, byte-for-byte as it
originally was. Only `argv` changes; every other field (`name`, `version`,
`bspVersion`, `languages`, and any backend-specific fields like
`sourcekit-xcode-bsp`'s `workspace`) passes through untouched, because
`install` operates on the parsed JSON object as a whole and only mutates
the `argv` key. This is also what makes the tool backend-agnostic: it never
needs to understand a specific backend's config schema, only the one
`argv` field every BSP backend declaration has by definition.

`--workspace-root` is baked in explicitly (rather than derived from
whatever cwd `sourcekit-lsp` happens to launch `argv` with) so project-key
derivation doesn't depend on an unconfirmed launch-time assumption. That
assumption is worth verifying empirically before relying on it even as a
cross-check.

`install` is idempotent: if `argv[0]` already resolves to `bsp-mux`, it's a
no-op unless `--force` is passed, in which case the existing wrapped argv
is unwrapped (split at `--`) and rewrapped, so repeated `--force` runs
never nest wrappers.

### Project key

SHA256 over:
- `realpath(workspace root)`
- resolved backend argv (the portion after `--`; `argv[0]` realpath'd so a
  symlinked or PATH-relative backend doesn't produce a different key than
  an equivalent absolute one)
- an explicit allowlist of environment variables: `DEVELOPER_DIR`,
  `TOOLCHAINS` — the ones that actually change which toolchain compiles the
  project. Deliberately *not* the full environment, which would cause
  spurious extra daemons from irrelevant env noise and defeat the point of
  deduping.

Socket/lockfile base directory: a short, fixed, per-user path directly
under `/tmp` (`/tmp/bsp-mux-<uid>/`), not under `$TMPDIR` — on Darwin that's
a long per-session path (`/var/folders/.../T/...`) that would consume most
of the `sockaddr_un` budget (~104 bytes total) on its own. Filenames are
the first 16 hex chars of the SHA256 (64 bits) to stay well within that
budget regardless of how long the actual workspace path is; the full hash
is recorded in a sidecar `<hash16>.meta.json` so a connecting client can
detect a truncated-hash collision instead of silently trusting it.

### Election race

`connect()` → succeeds → this process is a relay, done. This is the common
case (every editor window after the first) and never touches the lockfile
at all.

`connect()` fails (`ECONNREFUSED`/`ENOENT`; any other errno is a real error,
not an absence, and propagates) → loop:

1. `connect()` again → succeeds → relay, done.
2. Else, attempt `flock(LOCK_EX | LOCK_NB)` (non-blocking) on a companion
   lockfile.
   - **Acquired** → become the daemon: unlink a stale socket file if
     present (`bind()` fails with `EADDRINUSE` on an existing path
     regardless of whether anything's listening), `bind()`+`listen()`
     **before** spawning the backend so racing connects can queue instead
     of serializing behind backend startup latency, ignore `SIGPIPE`,
     detach the session (`setsid()`) — and **hold the flock for the
     daemon's entire lifetime**, released only by the kernel on crash or
     normal exit (no manual staleness detection needed, unlike a
     PID-in-lockfile scheme).
   - **Not acquired** → another process is either mid-election or is
     already the live daemon; sleep briefly and loop again.

The lock is deliberately **non-blocking** on the loser's side, not a
blocking `flock(LOCK_EX)`. A blocking acquire would be correct at the
instant of the race but wrong for the rest of the daemon's life: since the
daemon holds the lock until it exits, a blocking loser would hang for the
daemon's *entire remaining lifetime* instead of promptly reconnecting once
the daemon finishes `listen()` — a design that looks fine in isolation but
deadlocks the project's primary scenario (a second editor window opened
while the first is still running). The non-blocking-plus-poll form avoids
that while preserving the reason the lock is held for the daemon's whole
life in the first place: it turns "lock held" into an always-valid signal
for "a daemon is alive right now," not just "someone won the initial race."
That distinction matters because the socket file itself can be invalidated
out from under a live daemon (e.g. something external cleaning up under
`/tmp` — see below) without the daemon knowing; a contender that finds the
socket gone but the lock still held knows definitively not to start a
second one, and keeps polling `connect()` instead. Holding the lock for the
daemon's lifetime also removes the need to double-check `connect()` again
right after acquiring it: since a live daemon would still be holding the
lock, successfully acquiring it non-blocking is *by itself* proof no live
daemon currently exists — there's nothing left to double-check.

If the backend process crashes or its connection errors out mid-session:
fail all in-flight requests across every connected session, close
everything, unlink the socket, and exit. The next client action naturally
re-elects a fresh daemon and backend — simpler and more robust for a first
version than trying to respawn the backend and replay `initialize` in
place.

### Daemon-side state

Per project key, the daemon (an `actor` so all mutation is serialized
without hand-rolled locking) owns:

- The session registry (one entry per connected client — stdio for the
  process that won election, an accepted socket fd for every subsequent
  client; both look identical to the rest of the code via an abstract
  duplex-channel type).
- The single connection to the backend process.
- The cached `build/initialize` result, plus the params it was derived
  from. Every subsequent client's `initialize` is answered from this cache
  rather than forwarded — BSP assumes exactly one handshake per connection,
  and forwarding a second one is undefined behavior on the backend's side.
  A newly connecting client's params are compared against the cached ones
  as a defensive check; a mismatch fails loudly rather than silently
  replaying the wrong capabilities.
- Request-ID and `originId` rewrite tables, mapping the daemon's own
  backend-facing IDs back to `(session, client's original ID)`, since
  JSON-RPC IDs are chosen per-connection by each client and multiplexing
  several clients onto one backend connection means namespacing outbound
  IDs and demuxing responses back to whoever asked.
- A refcount of live sessions and an idle-grace-period timer.
  `build/shutdown` replies immediately without touching the backend;
  `build/exit` (or an abrupt disconnect, treated identically) decrements
  the refcount, and at zero starts the grace period before the real
  `shutdown`+`exit` goes to the backend and the daemon exits.

### Notification routing

- `buildTarget/didChange` and other graph-level notifications (no
  client-specific meaning — everyone's cached settings just went stale) are
  **broadcast** to every connected session.
- `build/taskStart`/`taskProgress`/`taskFinish` carry an `originId`
  correlating them to whichever request triggered the work — routed only
  to the session that owns that `originId` (default to broadcast if
  unmapped).
- `build/logMessage` goes to the daemon's own log file, not to any client —
  unattributable backend-internal logs aren't generally useful fanned out
  across N clients.
- Unknown/future notification methods default to broadcast, on the theory
  that over-delivering is safer than silently dropping something a client
  needed.

### Logging

File-based, never stdout (that's the wire protocol for whichever session is
running over the daemon's own stdio) and never bare stderr (once the
editor that originally launched the daemon exits while other clients
remain connected, stderr may point at a pipe with no reader — `SIGPIPE` is
ignored defensively, but routing real diagnostics to a file avoids the
problem rather than just surviving it).

## Dependency: `swift-tools-protocols`

[`swiftlang/swift-tools-protocols`](https://github.com/swiftlang/swift-tools-protocols)
(Apache-2.0), pinned `.exact("0.0.10")` — pre-1.0, no stability contract, so
pinned exactly rather than tracked, bumped deliberately. Provides:

- `BuildServerProtocol` — typed Swift structs for every BSP message
  (`InitializeBuildRequest`, `BuildShutdownRequest`,
  `OnBuildExitNotification`, `OnBuildInitializedNotification`,
  `OnBuildTargetDidChangeNotification`, `TaskStartNotification`,
  `TaskProgressNotification`, `TaskFinishNotification`,
  `OnBuildLogMessageNotification`, and the rest — confirmed against a real
  build of this package).
- `LanguageServerProtocolTransport` — `JSONRPCConnection`, the
  Content-Length-framed JSON-RPC transport BSP shares with LSP as its base
  protocol.

Both are confirmed `public` API, not `@_spi`-gated, so this project depends
on them directly rather than hand-rolling JSON-RPC framing or BSP types.

## Platform scope

Portable POSIX (macOS + Linux) from the start. The motivating case
(`sourcekit-xcode-bsp`) is Xcode/macOS-only, but the tool itself is generic
across any BSP backend, and some backends (Bloop, `sourcekit-bazel-bsp`)
are cross-platform — the design avoids Darwin-only APIs where a portable
POSIX equivalent exists.

## Repo layout

- `Sources/BSPMuxCore` — all logic, unit-testable in isolation:
  `ProjectKey`/`ProjectPaths` (key derivation, socket/lockfile paths),
  `Installer` (the `install` subcommand), `Election` (connect/flock race,
  daemon bootstrap), `Relay` (loser-of-election byte pump), `ClientSession`
  (per-connection state over an abstract duplex channel), `Daemon` (the
  actor holding all multiplexing state), `NotificationRouter` (broadcast
  vs. `originId`-routed classification).
- `Sources/bsp-mux` — thin CLI entry point.
- `Sources/fake-bsp-backend` — a minimal BSP backend test double, built
  against the same `BuildServerProtocol`/`LanguageServerProtocolTransport`
  dependencies so wire compatibility is automatic; used by the integration
  tests and available for manual testing without needing a real Xcode
  project.
- `Tests/BSPMuxCoreTests` — unit tests, no real processes or sockets.
- `Tests/BSPMuxIntegrationTests` — spawns real subprocesses via `Process`,
  drives `fake-bsp-backend`, exercises the full election/multiplexing flow
  end to end.

## Status

Implemented and tested: `ProjectKey`/`ProjectPaths` (key derivation, socket
path budget, meta round-trip), `Installer` (argv-splice `install`,
idempotency, `--force` unwrap/rewrap), both backed by injectable
`FileSystemProviding`/`PathResolving` seams so disk I/O and `realpath(3)`
resolution are fakeable in tests. `Election` (connect/flock race, daemon
bootstrap) is implemented behind an `ElectionEnvironment` seam and
unit-tested against a fake for its decision logic; its cross-process
guarantees (no split-brain on a cold-start race, no duplicate daemon if a
live daemon's socket is deleted out from under it, prompt takeover after a
crash) were verified once by hand against the real POSIX implementation but
are not yet in the automated suite — see Verification below.

Not yet implemented: `Relay`, `ClientSession`, `Daemon`, `NotificationRouter`,
the real `bsp-mux` CLI entry point, `fake-bsp-backend`, and the integration
test suite.

## Verification

- **Unit tests**: `ProjectKey` determinism and socket-path length bounds
  (done); `NotificationRouter` classification table; ID/`originId`
  rewrite-map mint→respond→prune lifecycle including unmapped-response
  handling; `Installer`'s argv-splice round-trip against an in-memory
  filesystem fake (done).
- **Integration tests** (real subprocesses, temp workspace dirs, driving
  `fake-bsp-backend`): two simulated clients converge on one backend
  process and one real `initialize` handshake; `originId`-routed
  notifications reach only the requesting client; broadcast notifications
  reach all clients; closing one client leaves others working; closing the
  last client tears down daemon and backend after the grace period and a
  fresh client can immediately re-elect; a backend killed mid-session fails
  in-flight requests promptly rather than hanging; a stale socket file with
  no listener is detected and cleaned up; rapid spawn/close churn never
  produces more than one live backend process at a time.
- **Manual smoke test** against a real `sourcekit-lsp` + `sourcekit-xcode-bsp`
  on an actual Xcode project: run `install`, open the workspace in two
  editor instances, confirm via `ps` that only one `sourcekit-xcode-bsp`
  process exists, confirm both editors get working completions/diagnostics,
  edit the project to trigger a real build-graph change and confirm both
  editors see updated compiler args, close editors one at a time and
  confirm the daemon/backend persist until the last one disconnects.
