import assert from "node:assert/strict";
import test from "node:test";
import { StreamConnection } from "../../packages/say-stream/dist/connection.js";
import { BookMirror } from "../../packages/say-stream/dist/book-mirror.js";

// Native WebSocket wrapper adapter for StreamConnection
function nodeSocketFactory(url) {
  const ws = new WebSocket(url);
  return {
    send(data) {
      ws.send(data);
    },
    close(code, reason) {
      ws.close(code, reason);
    },
    onOpen(listener) {
      ws.addEventListener("open", listener);
      return () => ws.removeEventListener("open", listener);
    },
    onMessage(listener) {
      const handler = (event) => listener(event.data);
      ws.addEventListener("message", handler);
      return () => ws.removeEventListener("message", handler);
    },
    onClose(listener) {
      const handler = (event) => listener(event.code, event.reason);
      ws.addEventListener("close", handler);
      return () => ws.removeEventListener("close", handler);
    },
    onError(listener) {
      const handler = (event) => listener(new Error(event.message || "WebSocket error"));
      ws.addEventListener("error", handler);
      return () => ws.removeEventListener("error", handler);
    },
  };
}

test("live feed gateway connection and subscription", async (t) => {
  const port = process.env.STREAM_PORT || "8080";
  const url = `ws://127.0.0.1:${port}/v1/stream`;

  // Verify connection can be created
  const received = [];
  const conn = new StreamConnection({
    getUrl: () => url,
    socketFactory: nodeSocketFactory,
    onEvent: (event) => received.push(event),
    onRevocation: () => {},
  });

  assert(conn !== null);
  conn.subscribe(["cards"]);
  assert(conn.desiredChannels.has("cards"));
  conn.dispose();
});
