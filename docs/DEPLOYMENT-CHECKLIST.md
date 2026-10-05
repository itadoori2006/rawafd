# Deployment checklist

- [ ] Rotate the previously exposed Cloudflare API token.
- [ ] Create/verify Supabase project.
- [ ] Run `supabase-migration.sql`.
- [ ] Restore `.open-next/assets` into `assets/` if available.
- [ ] `npm install`
- [ ] Set `SUPABASE_URL` secret.
- [ ] Set `SUPABASE_SERVICE_ROLE_KEY` secret.
- [ ] Set `RAWAFD_AUTH_SECRET` secret (32+ random characters).
- [ ] Set `DEFAULT_ADMIN_PASSWORD` secret.
- [ ] Optionally set `RESEND_API_KEY`.
- [ ] Create the first admin with `scripts/create-admin.mjs`.
- [ ] Run `npm run check:worker`.
- [ ] Run `npm run deploy`.
- [ ] Test `/`, login, admin, marketplace, and database persistence.
