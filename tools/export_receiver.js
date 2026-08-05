// Local-only receiver: Roblox Studio POSTs script sources here, we write them to disk.
const http = require("http");
const fs = require("fs");
const path = require("path");

const ROOT = process.argv[2];
const PORT = 8777;

const RESERVED = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/i;
const written = new Map(); // lowercased relpath -> true
let fileCount = 0;
let byteCount = 0;
const errors = [];

function sanitizeSegment(seg) {
  let s = seg.replace(/[<>:"/\\|?*\x00-\x1f]/g, "_");
  s = s.replace(/[. ]+$/g, "");
  if (s === "") s = "_";
  const base = s.split(".")[0];
  if (RESERVED.test(base)) s = "_" + s;
  return s;
}

function resolveTarget(relpath) {
  const parts = relpath.split("/").map(sanitizeSegment);
  let rel = parts.join("/");
  // De-duplicate: Roblox allows sibling instances with identical names.
  const ext = rel.match(/(\.(server|client)\.lua|\.lua)$/);
  const suffix = ext ? ext[0] : "";
  const stem = suffix ? rel.slice(0, -suffix.length) : rel;
  let candidate = rel;
  let n = 2;
  while (written.has(candidate.toLowerCase())) {
    candidate = `${stem}_${n}${suffix}`;
    n++;
  }
  written.set(candidate.toLowerCase(), true);
  return candidate;
}

function writeOne(item) {
  const rel = resolveTarget(item.relpath);
  const abs = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  const src = item.source == null ? "" : item.source;
  fs.writeFileSync(abs, src, "utf8");
  fileCount++;
  byteCount += Buffer.byteLength(src, "utf8");
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/stats") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ fileCount, byteCount, errors }));
    return;
  }
  let body = "";
  req.setEncoding("utf8");
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    if (req.url === "/write") {
      try {
        const items = JSON.parse(body);
        for (const item of items) {
          try {
            writeOne(item);
          } catch (e) {
            errors.push(`${item.relpath}: ${e.message}`);
          }
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: true, fileCount, byteCount }));
      } catch (e) {
        errors.push(`batch parse: ${e.message}`);
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
      return;
    }
    if (req.url === "/raw") {
      // {relpath, text} written verbatim, no extension logic
      try {
        const item = JSON.parse(body);
        const abs = path.join(ROOT, item.relpath);
        fs.mkdirSync(path.dirname(abs), { recursive: true });
        fs.writeFileSync(abs, item.text, "utf8");
        res.writeHead(200);
        res.end('{"ok":true}');
      } catch (e) {
        res.writeHead(400);
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
      return;
    }
    res.writeHead(404);
    res.end("no");
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`receiver listening on 127.0.0.1:${PORT} -> ${ROOT}`);
});
