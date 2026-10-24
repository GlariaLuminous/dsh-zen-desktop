// dsh-zen-proxy — Cordis plugin: in-process OpenAI-compatible proxy that
// injects OpenCode Zen official client headers on upstream requests.
//
// Why: the Zen gateway rate-limits free models for third-party clients by
// validating the User-Agent and x-opencode-* headers. dsh's LLM adapters
// forcibly send their own `user-agent` attribution header and cannot be
// configured to send the official opencode one, so a plain adapter cannot
// reach the free tier. This plugin runs a tiny local HTTP server (inside the
// dsh process, started/stopped with the profile) that rewrites the identity
// headers before forwarding to https://opencode.ai/zen/v1.
//
// Point the opencode provider baseURL in settings.yaml at the proxy:
//   llm-pi-ai.providers.opencode.baseURL: http://127.0.0.1:4097/v1
//
// Configuration (cordis.patch.yml):
//   - id: zen-proxy
//     name: 'dsh-zen-proxy'
//     config:
//       host: 127.0.0.1
//       port: 4097

import z from "@deepseek-ai/schemastery";
import http from "node:http";
import https from "node:https";

export const name = "zen-proxy";

export const Config = z.object({
  host: z.string().default("127.0.0.1"),
  port: z.number().default(4097),
  upstreamHost: z.string().default("opencode.ai"),
  upstreamBasePath: z.string().default("/zen/v1"),
  userAgent: z
    .string()
    .default("opencode/1.15.5 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14"),
  clientHeader: z.string().default("cli"),
  projectHeader: z.string().default("global"),
  maxBodyBytes: z.number().default(64 * 1024 * 1024),
  upstreamTimeoutMs: z.number().default(600000),
});

export const inject = [];

/** Deterministic per-request random id: `ses_` / `msg_` + 10 chars. */
const rnd = (p) => `${p}${Math.random().toString(36).slice(2, 12)}`;

/** Hop-by-hop headers must not be copied across the proxy boundary. */
const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

/**
 * @param {import("@deepseek-ai/cordis").Context} ctx
 * @param {z.infer<typeof Config>} config
 */
export function apply(ctx, config) {
  // 复用 TLS 连接：否则每次模型调用都要重新握手,首字延迟显著增加。
  const agent = new https.Agent({ keepAlive: true, maxSockets: 64 });

  const server = http.createServer((req, res) => {
    const { method, url } = req;

    // GET /v1/models — model-list discovery passthrough.
    if (method === "GET" && url === "/v1/models") {
      forward(req, res, { method: "GET", path: `${config.upstreamBasePath}/models`, body: null });
      return;
    }

    if (method !== "POST" || url !== "/v1/chat/completions") {
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { type: "not_found", message: `zen-proxy: unsupported ${method} ${url}` } }));
      return;
    }

    // 按 Buffer 收集并限制大小:字符串拼接会切断多字节 UTF-8 字符,无上限会被撑爆内存。
    const chunks = [];
    let size = 0;
    let tooLarge = false;
    req.on("data", (c) => {
      if (tooLarge) return;
      size += c.length;
      if (size > config.maxBodyBytes) {
        tooLarge = true;
        chunks.length = 0;
        res.writeHead(413, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            error: { type: "payload_too_large", message: `zen-proxy: request body exceeds ${config.maxBodyBytes} bytes` },
          })
        );
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      if (tooLarge) return;
      forward(req, res, { method: "POST", path: `${config.upstreamBasePath}/chat/completions`, body: Buffer.concat(chunks) });
    });
  });

  server.on("error", (error) => {
    ctx.logger.warn(`zen-proxy: server error: ${error.message}`);
  });

  ctx.effect(() => {
    server.listen(config.port, config.host, () => {
      ctx.logger.info(
        `zen-proxy: listening on http://${config.host}:${config.port}${config.upstreamBasePath} (upstream https://${config.upstreamHost})`
      );
    });
    return () => {
      server.closeAllConnections?.();
      server.close();
      agent.destroy();
    };
  }, "zen-proxy.server");

  /** Forward one request to the Zen upstream with official headers injected. */
  function forward(req, res, { method, path, body }) {
    const headers = {
      "content-type": "application/json",
      // Pass through the caller's Authorization if present; nothing else.
      ...(req.headers.authorization ? { authorization: req.headers.authorization } : {}),
      "user-agent": config.userAgent,
      "x-opencode-client": config.clientHeader,
      "x-opencode-project": config.projectHeader,
      "x-opencode-session": rnd("ses_"),
      "x-opencode-request": rnd("msg_"),
    };
    if (body !== null) headers["content-length"] = body.length;

    const out = https.request(
      {
        agent,
        host: config.upstreamHost,
        port: 443,
        method,
        path,
        headers,
      },
      (up) => {
        const outHeaders = {};
        for (const [k, v] of Object.entries(up.headers)) {
          if (!HOP_BY_HOP.has(k.toLowerCase())) outHeaders[k] = v;
        }
        res.writeHead(up.statusCode, outHeaders);
        up.pipe(res);
      }
    );

    // 上游无响应时不能无限挂住 socket。
    out.setTimeout(config.upstreamTimeoutMs, () => {
      out.destroy(new Error(`upstream timeout after ${config.upstreamTimeoutMs}ms`));
    });

    out.on("error", (e) => {
      ctx.logger.warn(`zen-proxy: upstream error: ${e.message}`);
      // 已经写过响应头时再 writeHead 会抛 ERR_HTTP_HEADERS_SENT,直接销毁连接。
      if (res.headersSent) {
        res.destroy();
        return;
      }
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { type: "bad_gateway", message: "zen-proxy: upstream request failed" } }));
    });

    // 客户端中途断开时释放上游连接,避免 socket 泄漏。
    res.on("close", () => {
      if (!res.writableEnded) out.destroy();
    });

    if (body !== null) out.end(body);
    else out.end();
  }
}
