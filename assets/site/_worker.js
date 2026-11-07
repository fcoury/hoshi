// Cloudflare Pages answers Range requests with the whole file (200), which
// breaks seeking (the film's chapter stars) and video playback in Safari.
// This serves byte ranges for videos; everything else passes straight through.
// _routes.json limits the worker to /img/*.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const range = request.headers.get("Range");
    if (!range || !url.pathname.endsWith(".mp4")) return env.ASSETS.fetch(request);

    const headers = new Headers(request.headers);
    headers.delete("Range");
    headers.delete("If-None-Match");
    headers.delete("If-Modified-Since");
    const res = await env.ASSETS.fetch(new Request(url, { headers }));
    const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (res.status !== 200 || !m || (m[1] === "" && m[2] === "")) return res;

    const body = await res.arrayBuffer();
    const size = body.byteLength;
    const start = m[1] === "" ? Math.max(0, size - Number(m[2])) : Number(m[1]);
    const end = m[1] !== "" && m[2] !== "" ? Math.min(Number(m[2]), size - 1) : size - 1;
    if (start >= size || start > end) {
      return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${size}` } });
    }
    const out = new Headers(res.headers);
    out.delete("Content-Encoding");
    out.set("Accept-Ranges", "bytes");
    out.set("Content-Range", `bytes ${start}-${end}/${size}`);
    out.set("Content-Length", String(end - start + 1));
    return new Response(request.method === "HEAD" ? null : body.slice(start, end + 1), { status: 206, headers: out });
  },
};
