import { createServer } from "node:http";
import worker from "./index.ts";
import { createLocalEnv } from "./localRuntime.ts";

const port = Number(process.env.PORT ?? "8787");
const env = createLocalEnv(process.env.SQLITE_PATH ?? ":memory:");

const server = createServer(async (req, res) => {
  try {
    const host = req.headers.host ?? `127.0.0.1:${port}`;
    const fullUrl = `http://${host}${req.url ?? "/"}`;
    const chunks: Buffer[] = [];
    for await (const chunk of req) {
      chunks.push(Buffer.from(chunk));
    }
    const bodyBuf = Buffer.concat(chunks);
    const method = (req.method ?? "GET").toUpperCase();

    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) {
      if (typeof v === "string") headers.set(k, v);
      else if (Array.isArray(v)) headers.set(k, v.join(", "));
    }

    const webReq = new Request(fullUrl, {
      method,
      headers,
      body:
        method === "GET" || method === "HEAD" || bodyBuf.byteLength === 0
          ? undefined
          : bodyBuf,
    });

    const webRes = await worker.fetch(webReq, env);
    res.statusCode = webRes.status;
    webRes.headers.forEach((val, key) => {
      res.setHeader(key, val);
    });
    const outBuf = Buffer.from(await webRes.arrayBuffer());
    res.end(outBuf);
  } catch (err: any) {
    res.statusCode = 500;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ error: err?.message ?? "Server error" }));
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(
    `[XDrive OrbitAPI] Local D1+R2 Server listening at http://127.0.0.1:${port}`
  );
});

