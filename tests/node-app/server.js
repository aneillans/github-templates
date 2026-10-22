import { createApp } from "./app.js";

const port = Number(process.env.PORT ?? 3000);
const server = createApp().listen(port, () => console.log(`listening on ${port}`));

// node is PID 1 in the container, so it gets no default SIGTERM handling
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
