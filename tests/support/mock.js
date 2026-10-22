// Serves index.html on a fake origin and answers Supabase REST/auth calls from fixtures.
const fs = require("fs");
const path = require("path");
const { tables, NOW } = require("./fixtures");

const ROOT = path.resolve(__dirname, "../..");
const ORIGIN = "http://pullfolio.test";
const SB = "https://nkjxyelfekgfjlfxkkvk.supabase.co";
const SB_UMD = path.join(ROOT, "node_modules/@supabase/supabase-js/dist/umd/supabase.js");
const USER = { id: "00000000-0000-0000-0000-000000000001", email: "tester@example.com", aud: "authenticated", role: "authenticated" };

function matches(row, key, expr){
  const v = row[key], s = v == null ? null : String(v);
  const neg = expr.startsWith("not."); if (neg) expr = expr.slice(4);
  const dot = expr.indexOf("."), op = expr.slice(0, dot), arg = expr.slice(dot + 1);
  let ok;
  if (op === "eq") ok = s === arg;
  else if (op === "neq") ok = s !== arg;
  else if (op === "is") ok = arg === "null" ? v == null : String(v) === arg;
  else if (op === "in") ok = arg.replace(/^\(|\)$/g, "").split(",").map(x => x.replace(/^"|"$/g, "")).includes(s);
  else if (op === "gt") ok = +v > +arg; else if (op === "gte") ok = +v >= +arg;
  else if (op === "lt") ok = +v < +arg; else if (op === "lte") ok = +v <= +arg;
  else if (op === "ilike") ok = new RegExp("^" + arg.replace(/[*%]/g, ".*") + "$", "i").test(s || "");
  else ok = true;
  return neg ? !ok : ok;
}
function order(rows, spec){
  const keys = spec.split(",").map(k => { const [col, dir = "asc", nulls] = k.split("."); return { col, desc: dir === "desc", nullsFirst: nulls === "nullsfirst" }; });
  return rows.slice().sort((a, b) => {
    for (const k of keys) {
      const x = a[k.col], y = b[k.col];
      if (x == null || y == null) { if (x == y) continue; return (x == null ? -1 : 1) * (k.nullsFirst ? 1 : -1); }
      const c = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y));
      if (c) return k.desc ? -c : c;
    }
    return 0;
  });
}

/**
 * Wire a page to the fixtures. Options:
 *  - flag: true/false forces PRICE_FALLBACK_ASKING in the served index.html (undefined = file as is)
 *  - mutate(db): edit fixture tables before the page loads
 * Returns { db, log } where log lists every REST request as { table, params }.
 */
async function setup(page, opts = {}){
  const db = tables(); if (opts.mutate) opts.mutate(db);
  const log = [];
  await page.clock.setFixedTime(NOW);
  await page.addInitScript(([user, now]) => {
    localStorage.setItem("sb-nkjxyelfekgfjlfxkkvk-auth-token", JSON.stringify({ access_token: "test", refresh_token: "test", token_type: "bearer",
      expires_in: 3600 * 24 * 365, expires_at: Math.floor(now / 1000) + 3600 * 24 * 365, user }));
  }, [USER, NOW]);
  await page.route(/fonts\.(googleapis|gstatic)\.com/, r => r.fulfill({ status: 200, body: "" }));
  await page.route(/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js/, r => r.fulfill({ status: 200, contentType: "application/javascript", body: fs.readFileSync(SB_UMD) }));
  await page.route(ORIGIN + "/**", r => {
    const u = new URL(r.request().url());
    let file = u.pathname === "/" ? "index.html" : u.pathname.slice(1);
    const fp = path.join(ROOT, file);
    if (!fs.existsSync(fp)) return r.fulfill({ status: 404, body: "" });
    let body = fs.readFileSync(fp);
    if (file === "index.html" && opts.flag !== undefined)
      body = body.toString().replace(/const PRICE_FALLBACK_ASKING = (true|false);/, "const PRICE_FALLBACK_ASKING = " + opts.flag + ";");
    r.fulfill({ status: 200, contentType: file.endsWith(".html") ? "text/html" : undefined, body });
  });
  await page.route(SB + "/**", async r => {
    const req = r.request(), u = new URL(req.url()), method = req.method();
    const json = (body, status = 200, headers = {}) => r.fulfill({ status, contentType: "application/json", headers: { "access-control-allow-origin": "*", "access-control-expose-headers": "content-range", ...headers }, body: JSON.stringify(body) });
    if (method === "OPTIONS") return r.fulfill({ status: 200, headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "*" } });
    if (u.pathname.startsWith("/auth/v1/user")) return json(USER);
    if (u.pathname.startsWith("/auth/")) return json({});
    const m = u.pathname.match(/^\/rest\/v1\/(rpc\/)?([^/]+)/); if (!m) return json({});
    if (m[1]) {
      const name = m[2], args = req.postDataJSON() || {};
      log.push({ table: "rpc/" + name, params: args });
      if (name === "catalog_stats") {
        const ps = db.catalog_v.filter(p => !args.p_sets || args.p_sets.includes(p.set_id));
        let value = 0, priced = 0;
        ps.forEach(p => { const r = db.price_v.find(x => x.product_id === p.id && x.condition === (args.p_cond || "NM") && (x.grade || "") === (args.p_grade || "")); if (r) { value += r.median; priced++; } });
        return json({ value, priced, count: ps.length });
      }
      return json(null);
    }
    const table = m[2];
    if (method !== "GET") { log.push({ table, method }); return json([]); }
    const params = [...u.searchParams.entries()];
    log.push({ table, params: Object.fromEntries(params) });
    let rows = (db[table] || []).slice();
    for (const [k, v] of params) {
      if (["select", "order", "limit", "offset", "or"].includes(k)) continue;
      rows = rows.filter(row => matches(row, k, v));
    }
    const total = rows.length;
    if (u.searchParams.get("order")) rows = order(rows, u.searchParams.get("order"));
    const off = +(u.searchParams.get("offset") || 0), lim = u.searchParams.get("limit");
    rows = rows.slice(off, lim != null ? off + +lim : undefined);
    const headers = (req.headers()["prefer"] || "").includes("count=") ? { "content-range": off + "-" + (off + rows.length - 1) + "/" + total } : {};
    return json(rows, 200, headers);
  });
  return { db, log };
}
async function open(page, opts){
  const ctx = await setup(page, opts);
  await page.goto(ORIGIN + "/");
  await page.locator("#sum b").first().waitFor();
  return ctx;
}
async function tab(page, name){
  await page.getByRole("tab", { name }).click();
}
module.exports = { setup, open, tab, ORIGIN };
