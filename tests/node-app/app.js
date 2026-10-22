import { createServer } from "node:http";

export function createApp() {
  return createServer((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ ok: true, path: req.url }));
  });
}
