export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);
    return Response.json({ ok: true, path: pathname });
  },
};
