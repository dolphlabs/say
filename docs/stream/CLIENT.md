# say-stream client

`@say/stream` is a framework-neutral TypeScript client for the Prompt 06
protocol. It provides transport lifecycle, event validation, book mirroring,
private hydration and scoped fallback polling. The package does not access
the database, Redis, or application REST endpoints.

## Build and test

```sh
cd packages/say-stream
npm install
npm run typecheck
npm test
```

`npm test` builds JavaScript and declarations into the ignored `dist/`
directory before running the Node test suite.

## Connection

The application supplies the URL/credential policy and event handlers. A
browser connection can use the existing session cookie:

```ts
import {
  BookMirror,
  browserSocketFactory,
  PrivateHydrator,
  StreamConnection,
} from "@say/stream";

let stream: StreamConnection;
let privateHydrator: PrivateHydrator;
const book = new BookMirror(marketId, {
  onResync: (channel) => stream.resync(channel),
});

stream = new StreamConnection({
  getUrl: (anonymous) => {
    const url = new URL("/v1/stream", window.location.href);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    if (anonymous) {
      url.searchParams.set("anonymous", "true");
    }
    return url.toString();
  },
  socketFactory: browserSocketFactory,
  onEvent: (event) => {
    if (event.type === "book.snapshot" || event.type === "book.reset") {
      book.installSnapshot(event);
    } else if (event.type === "book.delta") {
      book.apply(event);
    }
  },
  onError: (error) => reportStreamError(error),
  onReauthenticate: () => {
    privateHydrator.stop();
    clearPrivateApplicationState();
    showSignIn();
  },
});

stream.subscribe(["cards", "market:123e4567-e89b-42d3-a456-426614174000:book"]);
stream.connect();
```

The URL provider must not place credentials in application logs. On close
code `4001`, the connection drops `me`, calls `onReauthenticate`, and
reconnects through `getUrl(true)` so public subscriptions can continue
without the revoked credential. The application hook should clear its
private state and stop private hydration. Desired subscriptions are restored
after reconnect. `dispose()` removes listeners, cancels reconnect work and
closes the socket.

## Book mirror

Snapshots/reset payloads contain `depth`, integer `value`, `price_band`
(`min`, `max`, `tick`) and Yes-side `levels`. Sequence and epoch fields are
canonical uint64 decimal strings; quantities use the same representation.
Delta `from_seq` is the exclusive base. A delta is accepted only at the
current epoch and exact base sequence.

```ts
const book = new BookMirror(marketId, {
  onResync: (channel) => stream.resync(channel),
});

// For an asynchronous REST resync, capture the generation and pass it back
// so a superseded response cannot replace a newer baseline.
const generation = book.beginResync();
const snapshot = await reloadBook();
book.installSnapshot(snapshot, generation);

const yes = book.yesView();
const no = book.noView();
```

A gap, partial overlap, epoch change or uncovered top-depth membership
change marks the mirror stale and requests resync. A boundary-changing delta
must carry an authoritative `view` replacement. The No view complements
prices by `value - yes_price`, swaps sides, and sorts best-first. Do not
render stale mirrors as current.

## Private recovery

`PrivateHydrator` keeps application REST access in an injected reload hook.
The hook returns revisions for `orders`, `balance` and `positions`; matching
events remain buffered until the matching `resync.complete`. Old reload
promises and event generations cannot reactivate a newer hydration.

```ts
const privateHydrator = new PrivateHydrator({
  reload: () => loadPortfolioAndRevisions(),
  apply: (event) => applyPrivateEvent(event),
  requestResync: () => stream.resync("me"),
  acknowledge: (generation) => stream.resync("me", generation),
  onError: (error) => reportStreamError(error),
});
```

Call `privateHydrator.handle(event)` for `me` data/control events after
checking `isDataStreamEvent(event)`, and `stop()` when the authenticated
session ends. The application must ensure its reload returns a consistent
baseline with monotonic per-entity revisions; the client cannot manufacture
that guarantee from three unrelated HTTP responses.

## Fallback polling

`PollingFallback<T>` runs one abortable fetch at a time, defaults to a
jittered five-second interval, suppresses stale completions, and reports
errors to the application. Use one instance per authorized scope. Call
`invalidatePending()` when a newer WebSocket baseline arrives and `stop()`
when the scope is no longer active. The supplied `fetch` and `onValue`
handlers must compare their snapshot sequence/generation to the current
mirror; polling must not overwrite a newer stream update.

## Current limitation

The say service does not yet expose `/v1/stream` or its event sources. The
exchange runtime, market BookViews, private sharded streams, `session.revoked`
publication and bounded zokor writer hook are prerequisites to live
integration. These client APIs and contract tests do not claim a working
server gateway.
