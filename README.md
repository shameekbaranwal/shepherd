# shepherd

Mission control for a herd of terminal coding agents running under
[herdr](https://herdr.dev). The end goal is a macOS notch UI (boring.notch
fork) with live agent state, notifications, and context capture; this repo
holds the portable core.

## Packages

- **HerdBridge** (library) — the herdr-socket bridge: connection handling,
  typed models, and a live `HerdBridge` actor that hydrates from
  `session.snapshot` and follows the push event stream. UI-agnostic; also the
  home of the `AgentAdapter` / `Segment` extensibility interfaces (stubs for
  now).
- **herd** (executable) — phase-0 spike: a live terminal table of every agent
  with status colors, attention-first sorting, and a transition log.

## Run

```sh
swift build
./.build/debug/herd            # uses ~/.config/herdr/herdr.sock
HERDR_SOCKET_PATH=... ./.build/debug/herd
HERD_DEBUG=1 ./.build/debug/herd 2>debug.log   # raw wire + bridge logging
```

## herdr protocol notes (verified on the wire, herdr 0.7.x, protocol v16/v17)

Facts the docs don't spell out, learned by probing the socket:

1. **Connections are one-shot.** One request → one response → server closes
   the socket. Open a fresh connection per request.
2. **`events.subscribe` is the exception**: as the single request on a
   connection, it turns that connection into a dedicated push stream. Any
   further write on it makes the server close the connection. To change
   subscriptions, open a new connection with the full set, then close the old.
3. **Event replay:** on subscribe the server re-delivers recent buffered
   events. Consumers must tolerate stale deliveries (the bridge treats
   snapshots as truth and status events as idempotent deltas).
4. **Naming inconsistency:** pushed lifecycle events use underscores
   (`pane_agent_detected`, `tab_renamed`) but the agent status event is pushed
   as `pane.agent_status_changed` — with a dot.
5. **`pane_agent_detected` is noisy**: it fires periodically for every pane as
   re-detection. Only meaningful when it introduces an unknown agent pane or
   carries `released: true`.
6. **Per-pane subscriptions:** `pane.agent_status_changed` and
   `pane.output_matched` require a `pane_id`; lifecycle events are global.
   The bridge resubscribes with the full pane set whenever the herd's shape
   changes (debounced, leading-edge — trailing-edge debounce starves under
   event noise).

## Roadmap

Phase 0 (this): headless bridge + live table — done.
Phase 1+: notch tab (boring.notch fork), notifications/HUD, capture verbs +
routing, Shepherd supervisor daemon, flight recorder. The bridge stays a
standalone package so any shell can consume it.
