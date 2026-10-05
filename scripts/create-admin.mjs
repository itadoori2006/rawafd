#!/usr/bin/env node
// Creates (or updates) the first admin in Supabase. Run once after applying the migration:
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... ADMIN_EMAIL=you@example.com \
//   ADMIN_USERNAME=admin ADMIN_PASSWORD='a-long-unique-passphrase' node scripts/create-admin.mjs
import { randomBytes, scryptSync } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ADMIN_EMAIL, ADMIN_USERNAME = "admin", ADMIN_PASSWORD } = process.env;
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !ADMIN_EMAIL || !ADMIN_PASSWORD) {
  console.error("Missing env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ADMIN_EMAIL, ADMIN_PASSWORD"); process.exit(1);
}
if (ADMIN_PASSWORD.length < 12) { console.error("ADMIN_PASSWORD must be at least 12 characters"); process.exit(1); }

// same format the app verifies: "<salt>:<scrypt(password, salt, 64) as hex>"
const salt = randomBytes(16).toString("hex");
const passwordHash = `${salt}:${scryptSync(ADMIN_PASSWORD, salt, 64).toString("hex")}`;

const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const { error } = await sb.from("users").upsert({
  id: "user-admin-1", email: ADMIN_EMAIL.trim().toLowerCase(), username: ADMIN_USERNAME,
  password_hash: passwordHash, role: "admin", name: "RAWAFD Administrator", display_name: "RAWAFD Admin",
  email_verified: true, email_verified_at: new Date().toISOString(), status: "active", must_change_password: false,
}, { onConflict: "id" });
if (error) { console.error("Failed:", error.message); process.exit(1); }
console.log(`Admin ready: ${ADMIN_EMAIL}`);
