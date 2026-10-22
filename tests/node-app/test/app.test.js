import { test } from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../app.js";

test("responds with ok and the request path", async (t) => {
  const server = createApp().listen(0);
  t.after(() => server.close());
  await new Promise((resolve) => server.once("listening", resolve));

  const res = await fetch(`http://localhost:${server.address().port}/hello`);
  assert.deepEqual(await res.json(), { ok: true, path: "/hello" });
});
