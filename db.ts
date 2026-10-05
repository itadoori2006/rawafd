// Async Supabase-backed replacement for the old fs/JSON store (`db`, `persistDb`, `getDb`).
//
// WHY: the old store wrote JSON with fs.writeFileSync. Cloudflare Workers have no writable
// filesystem and each isolate keeps its own memory, so data vanished and diverged between
// requests. Every function here is ASYNC - callers must `await` them (the old ones were sync).
//
// Rows are snake_case in Postgres; objects exposed here are camelCase like the old store.
// Only top-level keys are converted; jsonb contents (packages, faqs, items...) are untouched.
import { supabaseAdmin } from "./supabase";

type Row = Record<string, any>;
const sb = () => supabaseAdmin();

const toSnake = (s: string) => s.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
const toCamel = (s: string) => s.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
// column renames where the app key is a reserved word in SQL
const ALIAS_OUT: Record<string, string> = { grp: "group" };
const ALIAS_IN: Record<string, string> = { group: "grp" };

const fromRow = <T = Row>(r: Row | null | undefined): T | null =>
  r ? (Object.fromEntries(Object.entries(r).map(([k, v]) => [ALIAS_OUT[k] ?? toCamel(k), v])) as T) : null;
const toRow = (o: Row): Row =>
  Object.fromEntries(
    Object.entries(o)
      .filter(([, v]) => v !== undefined)
      .map(([k, v]) => [ALIAS_IN[k] ?? toSnake(k), v]),
  );
const many = <T = Row>(rows: Row[] | null) => (rows ?? []).map((r) => fromRow<T>(r)!) ;

function check<T>(res: { data: T; error: any }, ctx: string): T {
  if (res.error) throw new Error(`[db:${ctx}] ${res.error.message}`);
  return res.data;
}
// escape % and _ so user input can't act as LIKE wildcards
const escapeLike = (s: string) => s.replace(/[\\%_]/g, (c) => "\\" + c);
const newId = (prefix: string) => `${prefix}-${crypto.randomUUID()}`;

/* ------------------------------ generic repo ------------------------------ */
export function repo<T extends { id: string } = any>(table: string) {
  return {
    async list(build?: (q: any) => any): Promise<T[]> {
      const q = sb().from(table).select("*");
      return many<T>(check(await (build ? build(q) : q), `${table}.list`));
    },
    async get(id: string): Promise<T | null> {
      return fromRow<T>(check(await sb().from(table).select("*").eq("id", id).maybeSingle(), `${table}.get`));
    },
    async insert(obj: Partial<T>): Promise<T> {
      const row = { id: (obj as any).id ?? newId(table), ...toRow(obj) };
      return fromRow<T>(check(await sb().from(table).insert(row).select().single(), `${table}.insert`))!;
    },
    async upsert(obj: Partial<T> & { id: string }): Promise<T> {
      return fromRow<T>(check(await sb().from(table).upsert(toRow(obj)).select().single(), `${table}.upsert`))!;
    },
    async update(id: string, patch: Partial<T>): Promise<T | null> {
      return fromRow<T>(check(await sb().from(table).update(toRow(patch)).eq("id", id).select().maybeSingle(), `${table}.update`));
    },
    async remove(id: string): Promise<void> {
      check(await sb().from(table).delete().eq("id", id), `${table}.remove`);
    },
  };
}

/* --------------------------------- users ---------------------------------- */
const users = repo("users");
export const getUserById = (id: string) => users.get(id);
export const getUsers = () => users.list((q) => q.order("created_at", { ascending: false }));

export async function getUserByEmail(email: string) {
  return fromRow(check(await sb().from("users").select("*").eq("email", email.trim().toLowerCase()).maybeSingle(), "users.byEmail"));
}
export async function getUserByUsernameOrEmail(value: string) {
  const v = value.trim();
  // two exact lookups instead of .or("...") so user input can never inject PostgREST filter syntax.
  // NOTE: the old store silently mapped aliases like "admin" to the first admin account; that is intentionally gone.
  const byEmail = await getUserByEmail(v);
  if (byEmail) return byEmail;
  return fromRow(check(await sb().from("users").select("*").ilike("username", escapeLike(v)).maybeSingle(), "users.byUsername"));
}
export const createUser = (u: Row) => users.insert({ ...u, email: String(u.email).trim().toLowerCase() });
export const updateUser = (id: string, patch: Row) => users.update(id, patch);

/* ------------------------------- sessions --------------------------------- */
const sessions = repo("sessions");
export async function createSession(p: { userId: string; ipAddress?: string; userAgent?: string; durationMs: number }) {
  const session = await sessions.insert({
    id: newId("sess"),
    userId: p.userId,
    ipAddress: p.ipAddress,
    userAgent: p.userAgent,
    expiresAt: new Date(Date.now() + p.durationMs).toISOString(),
  });
  return { session };
}
export const getSessionById = (id: string) => sessions.get(id);
export const touchSession = (id: string) => sessions.update(id, { lastActiveAt: new Date().toISOString() });
export const revokeSession = (id: string) => sessions.update(id, { revokedAt: new Date().toISOString() });
export const getSessions = () => sessions.list((q) => q.order("created_at", { ascending: false }).limit(500));

/* --------------------- login events + brute-force limiter ------------------ */
const loginEvents = repo("login_events");
export const logLoginEvent = (e: Row) => loginEvents.insert({ ...e, id: newId("log") });
export const getLoginEvents = (limit = 200) => loginEvents.list((q) => q.order("timestamp", { ascending: false }).limit(limit));

const WINDOW_MS = 15 * 60 * 1000;
const MAX_FAILS_PER_ACCOUNT = 5;
const MAX_FAILS_PER_IP = 20;
const isLoopback = (ip?: string) => !ip || ["127.0.0.1", "::1", "localhost", "::ffff:127.0.0.1"].includes(ip);

// Re-implementation of the old in-memory limiter (5 failures / 15 min per account, reset on success)
// plus a per-IP cap. Verify the thresholds against your intended policy.
export async function checkLoginRateLimit(identifier: string, ip?: string) {
  const since = new Date(Date.now() - WINDOW_MS).toISOString();
  const id = escapeLike(identifier.trim().toLowerCase());

  const lastOk = check(
    await sb().from("login_events").select("timestamp").eq("success", true).ilike("email", id)
      .gte("timestamp", since).order("timestamp", { ascending: false }).limit(1),
    "rl.lastOk",
  );
  const from = lastOk?.[0]?.timestamp ?? since;
  const fails = check(
    await sb().from("login_events").select("timestamp").eq("success", false).ilike("email", id)
      .gt("timestamp", from).order("timestamp", { ascending: true }).limit(50),
    "rl.fails",
  );
  if ((fails?.length ?? 0) >= MAX_FAILS_PER_ACCOUNT) {
    const retry = Math.ceil((new Date(fails![0].timestamp).getTime() + WINDOW_MS - Date.now()) / 1000);
    return { isBlocked: true, retryAfterSeconds: Math.max(retry, 1) };
  }
  if (!isLoopback(ip)) {
    const { count } = await sb().from("login_events").select("id", { count: "exact", head: true })
      .eq("success", false).eq("ip_address", ip!).gte("timestamp", since);
    if ((count ?? 0) >= MAX_FAILS_PER_IP) return { isBlocked: true, retryAfterSeconds: 60 };
  }
  return { isBlocked: false, retryAfterSeconds: 0 };
}

/* --------------------------- email verification --------------------------- */
export const createVerificationToken = (t: { userId: string; tokenHash: string; expiresAt: string }) =>
  repo("verification_tokens").insert({ id: newId("evt"), ...t });
// single atomic statement: a token can be consumed exactly once, and only before it expires
export async function consumeVerificationToken(tokenHash: string) {
  const now = new Date().toISOString();
  return fromRow(check(
    await sb().from("verification_tokens").update({ used_at: now })
      .eq("token_hash", tokenHash).is("used_at", null).gt("expires_at", now).select().maybeSingle(),
    "evt.consume",
  ));
}

/* ------------------------ marketplace: catalog & orders -------------------- */
export const getFreelancerProfile = async (userId: string) => {
  const r = check(await sb().from("freelancer_profiles").select("*").eq("user_id", userId).maybeSingle(), "fp.get");
  return r ? { userId: r.user_id, ...r.profile } : null;
};
export const getFreelancerProfiles = async () =>
  check(await sb().from("freelancer_profiles").select("*"), "fp.list")!.map((r: Row) => ({ userId: r.user_id, ...r.profile }));
export async function upsertFreelancerProfile(p: Row) {
  const { userId, ...profile } = p;
  check(await sb().from("freelancer_profiles").upsert({ user_id: userId, profile }), "fp.upsert");
  return p;
}

export const getCategories = () => repo("categories").list((q) => q.eq("is_active", true));
export const getCategoryById = (id: string) => repo("categories").get(id);

export async function getServices(f: {
  status?: string; visibility?: string; categoryId?: string; freelancerId?: string;
  query?: string; minPrice?: number; maxPrice?: number; maxDeliveryDays?: number;
} = {}) {
  return repo("services").list((q) => {
    if (f.status && f.status !== "all") q = q.eq("status", f.status);
    if (f.visibility && f.visibility !== "all") q = q.eq("visibility", f.visibility);
    if (f.categoryId && f.categoryId !== "all") q = q.eq("category_id", f.categoryId);
    if (f.freelancerId) q = q.eq("freelancer_id", f.freelancerId);
    if (typeof f.minPrice === "number") q = q.gte("price", f.minPrice);
    if (typeof f.maxPrice === "number") q = q.lte("price", f.maxPrice);
    if (typeof f.maxDeliveryDays === "number") q = q.lte("delivery_days", f.maxDeliveryDays);
    if (f.query?.trim()) {
      // allow-list characters: this string is interpolated into a PostgREST filter expression
      const s = f.query.replace(/[^\p{L}\p{N}\s\-_.]/gu, " ").trim();
      if (s) q = q.or(["title", "title_ar", "description", "description_ar", "freelancer_name"].map((c) => `${c}.ilike.%${s}%`).join(","));
    }
    return q.order("created_at", { ascending: false });
  });
}
export const getApprovedServices = () => getServices({ status: "approved", visibility: "public" });
export async function getServiceById(idOrSlug: string) {
  return (await repo("services").get(idOrSlug)) ??
    fromRow(check(await sb().from("services").select("*").eq("slug", idOrSlug).maybeSingle(), "services.bySlug"));
}
export const services = repo("services");
// soft-delete marker so seeded/demo services are not re-created
export const markServiceDeleted = async (id: string) => {
  check(await sb().from("deleted_service_ids").upsert({ id }), "svc.deleted");
  await services.remove(id);
};

export const orders = repo("orders");
export const getOrders = (filter?: { clientId?: string; freelancerId?: string }) =>
  orders.list((q) => {
    if (filter?.clientId) q = q.eq("client_id", filter.clientId);
    if (filter?.freelancerId) q = q.eq("freelancer_id", filter.freelancerId);
    return q.order("created_at", { ascending: false });
  });
export async function getOrderById(id: string) {
  const order = await orders.get(id);
  if (!order) return null;
  const [events, deliverables, messages, actions] = await Promise.all([
    repo("order_events").list((q) => q.eq("order_id", id).order("timestamp")),
    repo("order_deliverables").list((q) => q.eq("order_id", id).order("uploaded_at")),
    repo("order_messages").list((q) => q.eq("order_id", id).order("created_at")),
    repo("order_actions").list((q) => q.eq("order_id", id)),
  ]);
  return { ...order, events, deliverables, messages, actions };
}
export const addOrderMessage = (m: Row) => repo("order_messages").insert(m);
export const addOrderDeliverable = (d: Row) => repo("order_deliverables").insert(d);
export const addOrderEvent = (e: Row) => repo("order_events").insert(e);

/* ------------------------------ admin / ops -------------------------------- */
export const logEmail = (e: Row) => repo("emails").insert({ ...e, id: e.id ?? newId("email") });
export const getEmailEvents = (limit = 200) => repo("emails").list((q) => q.order("created_at", { ascending: false }).limit(limit));
export const addAdminAuditLog = (l: Row) => repo("admin_audit_logs").insert({ ...l, id: newId("audit") });
export const getAdminAuditLogs = (limit = 500) => repo("admin_audit_logs").list((q) => q.order("created_at", { ascending: false }).limit(limit));
export const addModerationLog = (l: Row) => repo("moderation_logs").insert({ ...l, id: newId("mod") });
export const createSecurityConsultation = (payload: Row) =>
  repo("security_consultations").insert({ id: newId("sec-req"), status: "submitted", payload });

/* ----------------------------------- CRM ----------------------------------- */
export const crm = {
  companies: repo("crm_companies"),
  contacts: repo("crm_contacts"),
  leads: repo("crm_leads"),
  deals: repo("crm_deals"),
  quotations: repo("crm_quotations"),
  tasks: repo("crm_tasks"),
  activities: repo("crm_activities"),
  auditLogs: repo("crm_audit_logs"),
};
