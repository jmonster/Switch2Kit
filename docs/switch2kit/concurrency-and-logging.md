# Concurrency, event delivery and diagnostics

## Ownership and immutable boundaries

A manager owns one private serial Bluetooth queue. The CoreBluetooth central, peripherals, mutable sessions, command serialization, calibration, retry/deadline state and discovery policy belong to that queue. Internal `@unchecked Sendable` transport/session declarations express that executor confinement; they are not permission to access mutable fields from arbitrary tasks. Public code never receives a peripheral, session, physical slot or implementation queue.

Public snapshots are immutable `Sendable` values. `Switch2ControllerManager` construction and observable presentation are main-actor isolated. Its command/observation methods are nonisolated and enqueue work; `currentSnapshot` is mutex-protected and may be read immediately from a worker. The `@Published snapshot` surface coalesces to roughly 10 Hz. These are different use cases: presentation sampling is not full-rate input recording.

The dashboard's output queue is now separate from the library's Bluetooth queue. Slow keyboard/network/UI adapters cannot synchronously hold a Bluetooth callback. A host-provided logging handler likewise runs on a separate utility queue.

## Bounded observation contract

`observe(on:bufferingNewest:handler:)` is the non-UI consumption mechanism. A retained `Switch2ControllerObservation` owns subscription lifetime; `cancel()` is idempotent and deallocation cancels. Registration accepts capacities 1–4096 and at most 32 observers, including the manager's internal presentation observer. Admission beyond that throws `observerLimitReached`.

Each observation has one mutex-protected bounded mailbox and at most one scheduled drain. Handler calls are serial for that observation even when the supplied queue is concurrent. Different observations can execute simultaneously and are not a lock for shared host state. A drain processes a bounded batch before rescheduling, not an infinite producer loop. No arbitrary caller work executes on the Bluetooth callback queue.

The initial event is a snapshot. At normal consumption speed, events preserve their transport order, and every decoded input report is available. On overflow, queued history is replaced by an authoritative current `.snapshot`; intermediate presses, releases or lifecycle transitions are not guaranteed to survive. The snapshot contains the entire ready set. Reconcile missing/replaced controllers and release held host outputs. Use `connectionID` and per-connection `state.sequence` to reset edge-sensitive state when delivery has a gap. Never describe this API as lossless for a slow consumer.

A session lifetime token gates pending input and connection delivery. Retirement clears mutable session callbacks/timers and invalidates that token before asynchronous cancellation. Queued retired input is discarded; an old snapshot containing a retired token is refreshed rather than reviving an old ready set. A host handler already executing cannot be retracted, nor can the library revoke immutable values the host has retained. Stop waits for transport teardown, not for arbitrary host work to finish.

## Commands and lifecycle

Start/stop are idempotent. Discovery windows are replaceable and generation-checked. Per-controller operations identify physical devices, not application player slots. Rumble intents coalesce in a bounded 64-ID inbox and carry the submitting session generation. Overflow reports `operationQueueFull` once per drain; an already-pending controller can still update its intent. Each session reuses one pulse-stop timer; a new pulse replaces its deadline rather than accumulating delayed callbacks. LED/RSSI operations use a 128-entry, batched queue with `operationQueueFull` backpressure. Delayed controls cannot operate on a replacement connection with the same device ID. Protocol commands inside a session remain serialized, bounded and reply-correlated.

Malformed local parameters throw synchronously. Actual availability, unsupported models and transport failures arrive as typed `.failure` events. A method returning does not mean a controller acknowledged it. Observation overflow may coalesce a failure into state resynchronization, so do not use the input channel as a durable transaction audit log.

## Privacy-conscious logging

Pass an optional `@Sendable (Switch2LogRecord) -> Void` handler and minimum `Switch2LogLevel` when constructing the manager. Levels are debug/info/warning/error; categories are typed. Internal `os.Logger` uses reviewed lifecycle text. The queue retains at most 128 records, drains batches, caps messages at 512 characters after a bounded UTF-8 prefix, and reports dropped-message counts under pressure.

Default diagnostics omit controller serials, local peripheral identifiers, raw manufacturer data, host bond material and sensor/audio/tag contents. Platform `Error.description` strings are not indiscriminately forwarded. Enabling `includeSerialNumbers` makes serials available in controller snapshots only; it does not enable serial logging. Treat IDs and opt-in serials as private even though they are useful routing values.

Switch2Kit opens no log files and creates no host Library directory. The host can display or persist records explicitly. The dashboard supplies its existing bounded `LogStore`/file pipeline, preserving its own rotation and user-facing log behavior; that is an application decision.

For a host log view, hand records to a bounded thread-safe inbox, schedule one coalesced main-actor drain, and cap retained rows. For persistence, choose an explicit destination, file size/rotation and privacy policy and write on a host utility queue. Do not recreate an unbounded main-actor task or file-write backlog per log record. A handler that blocks only slows diagnostic delivery, causing bounded drops; it does not block Bluetooth input.
