-- =============================================================================
-- RAWAFD  |  Supabase schema (replaces the fs-based JSON store in src/server/db.ts)
-- Run once: Supabase Dashboard -> SQL Editor, or `supabase db push`.
--
-- SECURITY MODEL
--   The app does its own auth (HMAC-signed cookie + sessions table), NOT Supabase
--   Auth. All DB access happens server-side with the SERVICE ROLE key. So:
--     * RLS is ENABLED on every table with NO policies  => anon/authenticated
--       keys (which ship to browsers) can read/write nothing.
--     * Privileges are also revoked from anon/authenticated as defense in depth.
--   Never expose the service role key to the browser (no NEXT_PUBLIC_ prefix).
-- =============================================================================

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

-- ---------- identity ----------------------------------------------------------
create table public.users (
  id                   text primary key,
  username             text,
  email                text not null,
  password_hash        text not null,                    -- "salt:scrypt-hex" (see scripts/create-admin.mjs)
  role                 text not null check (role in ('admin','freelancer','client')),
  name                 text not null,
  display_name         text,
  company_name         text,
  country              text,
  phone                text,
  email_verified       boolean not null default false,
  email_verified_at    timestamptz,
  status               text not null default 'active',   -- active | pending | suspended
  must_change_password boolean not null default false,
  last_login_at        timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create unique index users_email_uq    on public.users (lower(email));
create unique index users_username_uq on public.users (lower(username)) where username is not null;
create index users_role_idx           on public.users (role);

create table public.sessions (
  id             text primary key,
  user_id        text not null references public.users(id) on delete cascade,
  token_hash     text,
  created_at     timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  expires_at     timestamptz not null,
  revoked_at     timestamptz,
  ip_address     text,
  user_agent     text
);
create index sessions_user_idx    on public.sessions (user_id);
create index sessions_expires_idx on public.sessions (expires_at);

create table public.verification_tokens (
  id         text primary key,
  user_id    text not null references public.users(id) on delete cascade,
  token_hash text not null,
  expires_at timestamptz not null,
  used_at    timestamptz,
  created_at timestamptz not null default now()
);
create unique index verification_tokens_hash_uq on public.verification_tokens (token_hash);
create index verification_tokens_user_idx       on public.verification_tokens (user_id);

create table public.login_events (
  id             text primary key,
  user_id        text references public.users(id) on delete set null,
  email          text not null,
  role           text,
  event_type     text not null,                          -- login_success | login_failed | logout ...
  success        boolean not null,
  ip_address     text,
  user_agent     text,
  failure_reason text,
  "timestamp"    timestamptz not null default now()
);
create index login_events_email_ts_idx on public.login_events (lower(email), "timestamp" desc);
create index login_events_ip_ts_idx    on public.login_events (ip_address, "timestamp" desc);

-- ---------- marketplace -------------------------------------------------------
create table public.freelancer_profiles (
  user_id    text primary key references public.users(id) on delete cascade,
  profile    jsonb not null default '{}'::jsonb,         -- bio, skills, portfolio, etc.
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.categories (
  id             text primary key,
  name           text not null,
  name_ar        text,
  grp            text,                                   -- "group" is reserved in SQL
  description    text,
  description_ar text,
  icon           text,
  is_active      boolean not null default true,
  subcategories  jsonb not null default '[]'::jsonb
);

create table public.services (
  id                    text primary key,
  slug                  text,
  freelancer_id         text not null references public.users(id) on delete cascade,
  freelancer_name       text,
  freelancer_avatar     text,
  freelancer_country    text,
  title                 text not null,
  title_ar              text,
  category_id           text references public.categories(id) on delete set null,
  subcategory_id        text,
  description           text not null default '',
  description_ar        text,
  deliverables          jsonb not null default '[]'::jsonb,
  deliverables_ar       jsonb not null default '[]'::jsonb,
  delivery_days         integer not null default 7 check (delivery_days > 0),
  price                 numeric(12,2) not null default 0 check (price >= 0),
  currency              text not null default 'USD',
  images                jsonb not null default '[]'::jsonb,
  tags                  jsonb not null default '[]'::jsonb,
  status                text not null default 'draft',   -- draft | pending | approved | rejected | revision_requested
  visibility            text not null default 'public',
  is_demo               boolean not null default false,
  security_badges       jsonb,
  security_service_info jsonb,
  packages              jsonb not null default '[]'::jsonb,
  faqs                  jsonb not null default '[]'::jsonb,
  requirements          text,
  requirements_ar       text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create unique index services_slug_uq on public.services (slug) where slug is not null;
create index services_freelancer_idx on public.services (freelancer_id);
create index services_category_idx   on public.services (category_id);
create index services_status_idx     on public.services (status, visibility);

-- replaces `deletedServiceIds` (stops seed/demo services from being re-created)
create table public.deleted_service_ids (
  id         text primary key,
  deleted_at timestamptz not null default now()
);

create table public.orders (
  id                     text primary key,
  service_id             text references public.services(id) on delete set null,
  service_title          text,
  package_id             text,
  package_name           text,
  client_id              text references public.users(id) on delete set null,
  client_name            text,
  client_email           text,
  freelancer_id          text references public.users(id) on delete set null,
  freelancer_name        text,
  requirements           text,
  price                  numeric(12,2) not null default 0 check (price >= 0),
  currency               text not null default 'USD',
  delivery_days          integer,
  status                 text not null default 'pending',
  progress               integer not null default 0 check (progress between 0 and 100),
  expected_delivery_date timestamptz,
  last_update_at         timestamptz,
  next_step              text,
  next_step_ar           text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index orders_client_idx     on public.orders (client_id);
create index orders_freelancer_idx on public.orders (freelancer_id);
create index orders_service_idx    on public.orders (service_id);

create table public.order_events (
  id             text primary key,
  order_id       text not null references public.orders(id) on delete cascade,
  actor_name     text, actor_role text, type text,
  title          text, title_ar text, description text, description_ar text,
  "timestamp"    timestamptz not null default now()
);
create index order_events_order_idx on public.order_events (order_id, "timestamp");

create table public.order_deliverables (
  id          text primary key,
  order_id    text not null references public.orders(id) on delete cascade,
  title       text, title_ar text, file_name text, file_size bigint, file_url text,
  uploaded_by text, uploaded_at timestamptz not null default now(), status text
);
create index order_deliverables_order_idx on public.order_deliverables (order_id);

create table public.order_messages (
  id          text primary key,
  order_id    text not null references public.orders(id) on delete cascade,
  sender_id   text, sender_name text, sender_role text,
  content     text not null,
  created_at  timestamptz not null default now()
);
create index order_messages_order_idx on public.order_messages (order_id, created_at);

create table public.order_actions (        -- "act-review-*": pending actions shown on an order
  id text primary key,
  order_id text not null references public.orders(id) on delete cascade,
  type text, title text, title_ar text, description text, description_ar text,
  status text, action_cta_text text, action_cta_text_ar text
);
create index order_actions_order_idx on public.order_actions (order_id);

create table public.security_consultations (
  id         text primary key,
  status     text not null default 'submitted',
  payload    jsonb not null,                              -- contactName, companyName, email, ... as submitted
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- admin / ops -------------------------------------------------------
create table public.emails (
  id             text primary key,
  user_id        text references public.users(id) on delete set null,
  recipient      text not null, recipient_name text,
  type           text not null, status text not null default 'SENT',
  subject        text, subject_ar text, body_text text, body_html text, action_url text,
  created_at     timestamptz not null default now()
);
create index emails_created_idx on public.emails (created_at desc);

create table public.moderation_logs (
  id text primary key, service_id text, service_title text,
  admin_id text, admin_email text, action text not null, note text,
  "timestamp" timestamptz not null default now()
);
create table public.admin_audit_logs (
  id text primary key, admin_user_id text, admin_email text,
  action text not null, target_type text, target_id text, reason text,
  metadata jsonb, created_at timestamptz not null default now()
);
create index admin_audit_created_idx on public.admin_audit_logs (created_at desc);

-- ---------- CRM ---------------------------------------------------------------
create table public.crm_companies (
  id text primary key, name text not null, website text, industry text, country text, city text,
  size text, contact_ids jsonb not null default '[]'::jsonb, notes text,
  tags jsonb not null default '[]'::jsonb, total_revenue numeric(14,2) not null default 0,
  orders_count integer not null default 0, last_activity_at timestamptz, status text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.crm_contacts (
  id text primary key, user_id text references public.users(id) on delete set null,
  company_id text references public.crm_companies(id) on delete set null,
  name text not null, email text, phone text, job_title text, type text, notes text,
  tags jsonb not null default '[]'::jsonb, last_contacted_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index crm_contacts_company_idx on public.crm_contacts (company_id);

create table public.crm_leads (
  id text primary key, full_name text not null, company_name text, email text, phone text,
  country text, city text, source text, interested_service text,
  estimated_budget numeric(14,2), currency text default 'USD', lead_score integer default 0,
  status text not null default 'new', priority text, assigned_to text,
  tags jsonb not null default '[]'::jsonb, notes text,
  next_follow_up_date timestamptz, last_contact_date timestamptz, converted_client_id text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index crm_leads_status_idx on public.crm_leads (status);

create table public.crm_deals (
  id text primary key, title text not null, client_id text,
  company_id text references public.crm_companies(id) on delete set null,
  value numeric(14,2) not null default 0, currency text default 'USD',
  probability integer default 0 check (probability between 0 and 100),
  stage text not null default 'lead', owner text, interested_service text,
  expected_close_date timestamptz, notes text, quotation_id text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index crm_deals_stage_idx   on public.crm_deals (stage);
create index crm_deals_company_idx on public.crm_deals (company_id);

create table public.crm_quotations (
  id text primary key, quotation_number text not null, deal_id text references public.crm_deals(id) on delete set null,
  client_name text, client_email text, company_name text,
  items jsonb not null default '[]'::jsonb,
  subtotal numeric(14,2) not null default 0, discount numeric(14,2) not null default 0,
  tax_rate numeric(6,3) not null default 0, tax_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0, currency text default 'USD',
  valid_until timestamptz, notes text, terms text, status text not null default 'draft',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index crm_quotations_number_uq on public.crm_quotations (quotation_number);

create table public.crm_tasks (
  id text primary key, title text not null, description text, task_type text,
  due_date timestamptz, priority text, status text not null default 'open', assigned_user text,
  related_deal_id text references public.crm_deals(id) on delete set null, related_client_id text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index crm_tasks_status_due_idx on public.crm_tasks (status, due_date);

create table public.crm_activities (
  id text primary key, entity_type text not null, entity_id text not null,
  activity_type text, title text, title_ar text, description text, performed_by text,
  metadata jsonb, "timestamp" timestamptz not null default now()
);
create index crm_activities_entity_idx on public.crm_activities (entity_type, entity_id, "timestamp" desc);

create table public.crm_audit_logs (
  id text primary key, user_id text, user_email text, action text not null,
  entity_type text, entity_id text, details text, "timestamp" timestamptz not null default now()
);

-- ---------- updated_at triggers ----------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['users','freelancer_profiles','services','orders','security_consultations',
                           'crm_companies','crm_contacts','crm_leads','crm_deals','crm_quotations','crm_tasks']
  loop
    execute format('create trigger set_updated_at before update on public.%I
                    for each row execute function public.set_updated_at()', t);
  end loop;
end $$;

-- ---------- lock down: RLS on, no policies, no anon/authenticated access ------
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', r.tablename);
    execute format('revoke all on public.%I from anon, authenticated', r.tablename);
  end loop;
end $$;
revoke all on function public.set_updated_at() from anon, authenticated;

-- ---------- seed: marketplace categories (non-sensitive) ----------------------
insert into public.categories (id,name,name_ar,grp,description,description_ar,icon,is_active,subcategories) values
  ('web-development','Web Development','تطوير الويب والتطبيقات','technology','High-performance websites, Next.js web applications, and APIs.','مواقع إلكترونية فائقة الأداء، وتطبيقات ويب حديثة، وواجهات برمجة.','Globe',true,'[{"id": "full-stack", "name": "Full-Stack Web Apps", "nameAr": "تطبيقات ويب متكاملة"}, {"id": "corporate-sites", "name": "Corporate & Showcase Sites", "nameAr": "مواقع الشركات والتعريف بالأعمال"}, {"id": "ecommerce-web", "name": "E-Commerce Platforms", "nameAr": "متاجر ومنصات تجارة إلكترونية"}, {"id": "api-backend", "name": "API & Backend Systems", "nameAr": "بناء واجهات البرمجة والأنظمة الخلفية"}]'::jsonb),
  ('mobile-development','Mobile Development','تطوير تطبيقات الجوال','technology','iOS and Android apps using Flutter or React Native.','تطبيقات الهواتف الذكية لنظامي iOS وأندرويد باستخدام أحدث التقنيات.','Smartphone',true,'[{"id": "flutter-apps", "name": "Flutter Cross-Platform", "nameAr": "تطبيقات فلاتر متعددة المنصات"}, {"id": "react-native", "name": "React Native Apps", "nameAr": "تطبيقات React Native"}, {"id": "mobile-maintenance", "name": "App Maintenance & Upgrades", "nameAr": "صيانة وتحديث التطبيقات القائمة"}]'::jsonb),
  ('ai-automation','AI & Automation','الذكاء الاصطناعي والأتمتة','technology','Custom AI agents, workflow automation, and backend integrations.','وكلاء ذكاء اصطناعي، وأتمتة مسارات العمل، والربط البرمجي للأنظمة.','Bot',true,'[{"id": "ai-agents", "name": "AI Agents & Assistants", "nameAr": "المساعدون الرقميون والوكلاء"}, {"id": "workflow-automation", "name": "Workflow Automation (n8n/Make)", "nameAr": "أتمتة العمليات (n8n / Make)"}, {"id": "document-processing", "name": "Document & OCR Processing", "nameAr": "معالجة المستندات واستخراج البيانات"}]'::jsonb),
  ('cybersecurity','Cybersecurity Services','خدمات الأمن السيبراني','technology','Protect your systems, applications, data, and digital infrastructure with professional cybersecurity services from qualified security specialists.','احمِ أنظمتك وتطبيقاتك وبياناتك وبنيتك الرقمية مع خدمات أمن سيبراني احترافية من متخصصين وخبراء معتمدين.','ShieldCheck',true,'[{"id": "penetration-testing", "name": "Penetration Testing (Ethical Hacking)", "nameAr": "اختبار الاختراق الأخلاقي المعتمد"}, {"id": "security-assessment", "name": "Security Assessment & Vulnerability Scanning", "nameAr": "تقييم الثغرات والمسح الأمني"}, {"id": "soc-monitoring", "name": "SOC & SIEM Deployment (Wazuh / Splunk)", "nameAr": "مركز العمليات الأمنية والمراقبة"}, {"id": "incident-response", "name": "Incident Response & Digital Forensics", "nameAr": "الاستجابة للحوادث والأدلة الرقمية"}, {"id": "cloud-security", "name": "Cloud Security (AWS / Azure / GCP)", "nameAr": "أمن الحوسبة السحابية"}, {"id": "application-security", "name": "Application Security & DevSecOps", "nameAr": "أمن التطبيقات ودورة التطوير الآمن"}, {"id": "compliance-governance", "name": "Compliance & Governance (ISO / PCI Readiness)", "nameAr": "الامتثال والحوكمة الأمنية"}]'::jsonb),
  ('custom-software-crm','Custom Software & CRM','البرمجيات المخصصة وأنظمة CRM','technology','Bespoke commercial software, custom CRM pipelines, and operations engines with 100% source code ownership.','برمجيات مخصصة وأنظمة CRM متطورة تدير المبيعات والعمليات التجارية مع تسليم كامل الكود المصدري.','Briefcase',true,'[{"id": "crm-pipelines", "name": "Custom CRM & Sales Pipelines", "nameAr": "أنظمة CRM ومسارات المبيعات"}, {"id": "internal-tools", "name": "Internal Operations Portals", "nameAr": "بوابات العمليات والأدوات الداخلية"}, {"id": "quotation-billing", "name": "Quotation & Invoicing Engines", "nameAr": "محركات عروض الأسعار والفوترة"}]'::jsonb),
  ('ui-ux-design','UI/UX Design','تصميم واجهات وتجربة المستخدم','design','Figma design systems, wireframing, and user-centered product design.','أنظمة تصميم فيغما، وهيكلة تجربة المستخدم، والنماذج التفاعلية.','Layout',true,'[{"id": "figma-systems", "name": "Figma Design Systems", "nameAr": "أنظمة تصميم فيغما الشاملة"}, {"id": "product-ux", "name": "SaaS & Dashboard UX", "nameAr": "تصميم المنصات ولوحات التحكم"}, {"id": "mobile-ui", "name": "Mobile App UI Design", "nameAr": "تصميم واجهات تطبيقات الجوال"}]'::jsonb),
  ('graphic-design','Graphic & Brand Design','الهوية البصرية والتصميم الجرافيكي','design','Corporate visual identities, guidelines, and marketing collateral.','الهويات البصرية للشركات، وأدلة استخدام العلامة، والمواد التسويقية.','Palette',true,'[{"id": "brand-identity", "name": "Complete Brand Identity", "nameAr": "هوية بصرية متكاملة"}, {"id": "social-visuals", "name": "Social Media Kits", "nameAr": "حزم تصاميم المنصات الاجتماعية"}, {"id": "presentation-deck", "name": "Pitch Decks & Presentations", "nameAr": "عروض تقديمية وملفات أعمال"}]'::jsonb)
on conflict (id) do nothing;
