// Supabase Edge Function 'track' — 홈페이지 유입 기록(공개)과 관리자 유입 분석(로그인 필요)
// 표: public.visit_events (sql/visit_events.sql). 개인정보는 받지도 저장하지도 않는다.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";

const ORIGINS = ["https://the990.co.kr", "https://www.the990.co.kr"];
const STAGES = ["visit", "start", "card", "complete", "fail", "inquiry"];
const PAGES = ["main", "spinning"];

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

function cors(req: Request) {
  const o = req.headers.get("origin") || "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0],
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  };
}
const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
const clean = (v: unknown, max: number) => String(v ?? "").replace(/[\u0000-\u001f<>]/g, "").trim().slice(0, max);

// 관리자 토큰 검증 — 관리자 서버(api/admin, crm)와 같은 방식
const sha = (s: string) => createHash("sha256").update(String(s)).digest();
const same = (a: string, b: string) => timingSafeEqual(sha(a), sha(b));
async function setting(key: string): Promise<string | null> {
  const { data, error } = await db.from("admin_settings").select("value").eq("key", key).maybeSingle();
  return error || !data ? null : (data.value as string);
}
async function isAdmin(req: Request): Promise<boolean> {
  const h = req.headers.get("authorization") || "";
  const token = h.startsWith("Bearer ") ? h.slice(7) : "";
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return false;
  const [hash, secret] = await Promise.all([setting("admin_password_hash"), setting("token_secret")]);
  if (!secret) return false;
  const key = sha(`990gym-admin|${hash || ""}|${secret}`);
  if (!same(sig, createHmac("sha256", key).update(payload).digest("base64url"))) return false;
  try {
    return Number(JSON.parse(Buffer.from(payload, "base64url").toString()).exp) > Date.now();
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return json(req, { error: "method" }, 405);

  let b: Record<string, unknown> = {};
  try { b = JSON.parse(await req.text()); } catch { return json(req, { error: "bad body" }, 400); }

  // ── 관리자: 유입 분석 ──
  if (b.action === "report") {
    if (!(await isAdmin(req))) return json(req, { error: "unauthorized" }, 401);
    const days = Math.min(Math.max(parseInt(String(b.days)) || 7, 1), 365);
    const page = PAGES.includes(String(b.page)) ? String(b.page) : null;
    const from = new Date(Date.now() - days * 86400000).toISOString();
    const [rep, rec, first] = await Promise.all([
      db.rpc("visit_report", { p_from: from, p_page: page }),
      db.rpc("visit_recent", { p_from: from, p_page: page, p_limit: 40 }),
      db.from("visit_events").select("created_at").order("created_at", { ascending: true }).limit(1).maybeSingle(),
    ]);
    if (rep.error || rec.error) return json(req, { error: (rep.error || rec.error)!.message }, 500);
    return json(req, { days, page, rows: rep.data, recent: rec.data, since: first.data?.created_at || null });
  }

  // ── 관리자: 전체 기록 (한 줄씩) ──
  if (b.action === "rows") {
    if (!(await isAdmin(req))) return json(req, { error: "unauthorized" }, 401);
    const days = Math.min(Math.max(parseInt(String(b.days)) || 7, 1), 365);
    const page = PAGES.includes(String(b.page)) ? String(b.page) : null;
    const max = Math.min(Math.max(parseInt(String(b.limit)) || 200, 1), 5000);
    const from = new Date(Date.now() - days * 86400000).toISOString();
    const rows: unknown[] = [];
    while (rows.length < max) {
      let q = db.from("visit_events").select("created_at, source, stage, page, app, medium, campaign, visitor_id")
        .gte("created_at", from).order("created_at", { ascending: false }).order("id", { ascending: false })
        .range(rows.length, Math.min(rows.length + 1000, max) - 1);
      if (page) q = q.eq("page", page);
      const { data, error } = await q;
      if (error) return json(req, { error: error.message }, 500);
      rows.push(...(data || []));
      if (!data || data.length < 1000) break;
    }
    return json(req, { days, page, rows, capped: rows.length >= max });
  }

  // ── 공개: 유입 기록 한 줄 ──
  const ua = req.headers.get("user-agent") || "";
  if (/bot|crawl|spider|facebookexternalhit|preview|headless|lighthouse/i.test(ua)) return json(req, { ok: true });
  const origin = req.headers.get("origin");
  if (origin && !ORIGINS.includes(origin)) return json(req, { ok: true });

  const vid = clean(b.vid, 40);
  const stage = String(b.stage);
  const page = String(b.page);
  if (!/^[a-z0-9]{8,40}$/.test(vid) || !STAGES.includes(stage) || !PAGES.includes(page)) return json(req, { error: "bad event" }, 400);

  let source = clean(b.src, 30);
  let medium = clean(b.med, 30);
  let campaign = clean(b.camp, 60);
  // 카드 등록 뒤 다른 브라우저로 돌아와 경로를 잃은 경우: 같은 방문자의 처음 기록에서 가져온다
  if (!source) {
    const { data } = await db.from("visit_events").select("source, medium, campaign").eq("visitor_id", vid)
      .order("created_at", { ascending: true }).limit(1).maybeSingle();
    source = data?.source || "직접 유입";
    medium = medium || data?.medium || "";
    campaign = campaign || data?.campaign || "";
  }

  const { error } = await db.from("visit_events").insert({
    visitor_id: vid, stage, page, source, medium: medium || null, campaign: campaign || null, app: clean(b.app, 20) || null,
  });
  if (error) return json(req, { error: "save failed" }, 500);
  return json(req, { ok: true });
});
