# RAWAFD — Cloudflare Worker + Pages-ready package

This package is based on the uploaded `rawafd.fixed.js` OpenNext/Cloudflare Worker bundle and the supplied Supabase migration/client files.

## Recommended deployment: Cloudflare Workers

The application is a dynamic Next.js/OpenNext Worker, so **Workers is the primary deployment target**. The root `wrangler.jsonc` configures:

- the compiled Worker entry point (`worker.js`)
- Cloudflare static assets via the `ASSETS` binding
- Node.js compatibility required by the generated bundle
- the three Durable Object classes exported by the bundle
- SQLite-backed Durable Object migrations

### 1. Install

```bash
npm install
```

### 2. Authenticate

```bash
npx wrangler login
```

If you use an API token, prefer an environment variable rather than putting it in a file:

```bash
export CLOUDFLARE_API_TOKEN="YOUR_NEW_TOKEN"
```

On Windows PowerShell:

```powershell
$env:CLOUDFLARE_API_TOKEN="YOUR_NEW_TOKEN"
```

### 3. Set production secrets

```bash
npx wrangler secret put SUPABASE_URL --config wrangler.jsonc
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY --config wrangler.jsonc
npx wrangler secret put RAWAFD_AUTH_SECRET --config wrangler.jsonc
npx wrangler secret put DEFAULT_ADMIN_PASSWORD --config wrangler.jsonc
```

Optional email secrets, depending on the provider:

```bash
npx wrangler secret put RESEND_API_KEY --config wrangler.jsonc
```

### 4. Prepare Supabase

Run `supabase-migration.sql` against the Supabase project first. The migration enables RLS and intentionally does not grant public table access; the application uses the server-side service-role key.

### 5. Create the first admin

The supplied `scripts/create-admin.mjs` is a Node-side setup script and is **not** part of the Worker runtime.

```bash
SUPABASE_URL="..." \
SUPABASE_SERVICE_ROLE_KEY="..." \
ADMIN_EMAIL="you@example.com" \
ADMIN_USERNAME="admin" \
ADMIN_PASSWORD="use-a-long-unique-password" \
node scripts/create-admin.mjs
```

### 6. Deploy

```bash
npm run check:worker
npm run deploy
```

## Cloudflare Pages compatibility

`pages/_worker.js` contains the same Worker bundle and `wrangler.pages.jsonc` provides a Pages-compatible Worker configuration. However, this app depends on Durable Objects exported by the Worker bundle. Cloudflare's current Pages model requires Durable Object namespaces to be provided by a separate Worker; they are not created directly inside a Pages project.

Therefore, **use the Worker deployment for the complete RAWAFD application**. The Pages configuration is provided as a compatibility starting point, not as a claim that Pages alone can reproduce all Worker + Durable Object functionality.

## Important limitation from the uploaded ZIP

The uploaded archive did **not** include the original `.open-next/assets` output directory. The compiled Worker references the `ASSETS` binding, so the application may not have its original browser-side JS/CSS/static files until those generated assets are restored.

If you have the original `.open-next/assets` directory, copy its contents into `assets/` before deploying.

## Security

The Cloudflare API token previously pasted into ChatGPT should be considered exposed. Revoke/rotate it and use a newly generated token for deployment.

Never commit:

- `CLOUDFLARE_API_TOKEN`
- `SUPABASE_SERVICE_ROLE_KEY`
- `RAWAFD_AUTH_SECRET`
- `DEFAULT_ADMIN_PASSWORD`
- `RESEND_API_KEY`

The existing bundle was already patched according to the supplied `SETUP.md`; the source-level security fixes still need to be re-applied and the application rebuilt if the source project is recovered.
