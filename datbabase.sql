-- =========================================================
-- Deadline.AI – Supabase SQL (EU-ready)
-- Datenmodell + RLS-Policies
-- =========================================================

-- Extensions (für UUID, Cron optional)
create extension if not exists "pgcrypto";
create extension if not exists "pg_trgm";
create extension if not exists "pg_stat_statements";

-- =========================================================
-- 1) Mandanten & Nutzer
-- =========================================================
create table if not exists organisation (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  plan text not null default 'trial',
  created_at timestamptz not null default now()
);

-- Hinweis: app_user verknüpft den auth.users Eintrag mit einer Organisation
create table if not exists app_user (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  organisation_id uuid not null references organisation(id) on delete cascade,
  email text not null,
  name text,
  role text not null check (role in ('owner','admin','member','viewer')),
  created_at timestamptz not null default now(),
  last_login_at timestamptz
);

create index if not exists idx_app_user_org on app_user(organisation_id);
create index if not exists idx_app_user_auth on app_user(auth_user_id);

-- =========================================================
-- 2) Dokumente
-- =========================================================
create table if not exists document (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  uploader_user_id uuid references app_user(id) on delete set null,
  title text,
  doc_type text check (doc_type in ('vertrag','agb','angebot','nachtrag','zertifikat','sonstiges')),
  counterparty text,
  governing_law text,
  currency text,
  storage_url text not null,          -- S3/Storage Pfad
  text_extracted boolean not null default false,
  ocr_language text default 'de',
  text_content tsvector,              -- optional: Volltextindex
  raw_text text,                      -- optional: für Trace/Debug
  signature_date date,
  effective_date date,
  created_at timestamptz not null default now()
);
create index if not exists idx_document_org on document(organisation_id);
create index if not exists idx_document_text on document using gin (text_content);

-- =========================================================
-- 3) Anchors (Referenzdaten pro Dokument)
-- =========================================================
create table if not exists anchor (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references document(id) on delete cascade,
  name text not null,                 -- z.B. 'delivery_date', 'acceptance_date', 'custom:inbetriebnahme'
  anchor_date date not null
);
create index if not exists idx_anchor_doc_name on anchor(document_id, name);

-- =========================================================
-- 4) Deadlines
-- =========================================================
create table if not exists deadline (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references document(id) on delete cascade,
  type text not null check (type in (
    'kuendigung','auto_verlaengerung','abnahme','maengelruege',
    'gewaehrleistung_ende','zahlung','claim','option',
    'liefertermin','meilenstein','sonstiges'
  )),
  label text not null,
  source_excerpt text,
  source_page int,
  computation jsonb not null,         -- {expression, relative, anchor, offset_days, offset_months, anchor_name_if_custom}
  absolute_due_date date,
  requires_anchor boolean not null default false,
  is_controlling_if_conflict boolean not null default false,
  confidence numeric(3,2) not null check (confidence>=0 and confidence<=1),
  notes text,
  created_at timestamptz not null default now()
);
create index if not exists idx_deadline_doc on deadline(document_id);
create index if not exists idx_deadline_due on deadline(absolute_due_date);
create index if not exists idx_deadline_type on deadline(type);

create table if not exists deadline_window (
  deadline_id uuid primary key references deadline(id) on delete cascade,
  opens date,
  closes date
);

create table if not exists reminder_policy (
  deadline_id uuid primary key references deadline(id) on delete cascade,
  days_before int[] not null default '{90,30,7,1}'
);

-- Materialisierte Reminder (konkrete Schüsse)
create table if not exists reminder (
  id uuid primary key default gen_random_uuid(),
  deadline_id uuid not null references deadline(id) on delete cascade,
  fire_at timestamptz not null,
  channel text not null check (channel in ('email','sms','whatsapp','slack','teams','ical')),
  status text not null default 'scheduled' check (status in ('scheduled','sent','skipped','failed')),
  sent_at timestamptz,
  meta jsonb
);
create index if not exists idx_reminder_due on reminder(fire_at, status);
create index if not exists idx_reminder_deadline on reminder(deadline_id);

-- =========================================================
-- 5) Kalender-Integration
-- =========================================================
create table if not exists calendar_account (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  provider text not null check (provider in ('google','microsoft','ics')),
  account_email text,
  access_token text,                  -- verschlüsselt extern speichern empfohlen
  refresh_token text,
  token_expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists calendar_event (
  id uuid primary key default gen_random_uuid(),
  deadline_id uuid not null references deadline(id) on delete cascade,
  calendar_account_id uuid references calendar_account(id) on delete set null,
  provider_event_id text,
  title text not null,
  starts_at timestamptz not null,
  all_day boolean not null default true,
  status text not null default 'created' check (status in ('created','updated','deleted','failed')),
  last_sync_at timestamptz
);
create index if not exists idx_calendar_event_account on calendar_event(calendar_account_id);

-- =========================================================
-- 6) E-Mail Inbound & Konflikte & Audit
-- =========================================================
create table if not exists email_inbound (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id) on delete cascade,
  message_id text unique,
  from_address text,
  to_address text,
  subject text,
  received_at timestamptz not null default now(),
  attachment_count int not null default 0,
  processed boolean not null default false,
  processing_notes text
);
create index if not exists idx_email_inbound_org_time on email_inbound(organisation_id, received_at desc);

create table if not exists deadline_conflict (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references document(id) on delete cascade,
  conflict_reason text,
  chosen_controlling_deadline uuid references deadline(id)
  -- optional: Mapping auf Indizes kann clientseitig erfolgen
);

create table if not exists audit_log (
  id bigserial primary key,
  organisation_id uuid not null references organisation(id) on delete cascade,
  actor_user_id uuid references app_user(id) on delete set null,
  entity text not null,
  entity_id uuid not null,
  action text not null,               -- created/updated/deleted/sent/…
  diff jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_audit_org_time on audit_log(organisation_id, created_at desc);

-- =========================================================
-- 7) RLS: Row Level Security aktivieren
-- =========================================================
alter table organisation enable row level security;
alter table app_user enable row level security;
alter table document enable row level security;
alter table anchor enable row level security;
alter table deadline enable row level security;
alter table deadline_window enable row level security;
alter table reminder_policy enable row level security;
alter table reminder enable row level security;
alter table calendar_account enable row level security;
alter table calendar_event enable row level security;
alter table email_inbound enable row level security;
alter table deadline_conflict enable row level security;
alter table audit_log enable row level security;

-- Helper: Policy-Prinzip
-- Zugriffe sind erlaubt, wenn der aufrufende auth.user Mitglied (app_user) derselben Organisation ist.

-- ========== organisation ==========
drop policy if exists org_read on organisation;
create policy org_read on organisation
for select using (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = organisation.id
  )
);

-- Owner/Admin können eigene Organisation updaten
drop policy if exists org_update on organisation;
create policy org_update on organisation
for update using (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = organisation.id
      and u.role in ('owner','admin')
  )
);

-- ========== app_user ==========
drop policy if exists app_user_select on app_user;
create policy app_user_select on app_user
for select using (
  exists (
    select 1 from app_user me
    where me.auth_user_id = auth.uid()
      and me.organisation_id = app_user.organisation_id
  )
);

-- Owner/Admin dürfen Mitglieder-Records schreiben  
create policy app_user_update on app_user
for update
using (
  exists (
    select 1 from app_user me
    where me.auth_user_id = auth.uid()
      and me.organisation_id = app_user.organisation_id
      and me.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1 from app_user me
    where me.auth_user_id = auth.uid()
      and me.organisation_id = app_user.organisation_id
      and me.role in ('owner','admin')
  )
);

-- ========== document ==========
drop policy if exists document_all on document;
create policy document_all on document
for all using (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = document.organisation_id
  )
) with check (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = document.organisation_id
  )
);

-- ========== anchor ==========
drop policy if exists anchor_all on anchor;
create policy anchor_all on anchor
for all using (
  exists (
    select 1
    from document d
    join app_user u on u.organisation_id = d.organisation_id
    where d.id = anchor.document_id
      and u.auth_user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from document d
    join app_user u on u.organisation_id = d.organisation_id
    where d.id = anchor.document_id
      and u.auth_user_id = auth.uid()
  )
);

-- ========== deadline ==========
drop policy if exists deadline_all on deadline;
create policy deadline_all on deadline
for all using (
  exists (
    select 1
    from document d
    join app_user u on u.organisation_id = d.organisation_id
    where d.id = deadline.document_id
      and u.auth_user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from document d
    join app_user u on u.organisation_id = d.organisation_id
    where d.id = deadline.document_id
      and u.auth_user_id = auth.uid()
  )
);

-- ========== deadline_window ==========
drop policy if exists deadline_window_all on deadline_window;
create policy deadline_window_all on deadline_window
for all using (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = deadline_window.deadline_id
      and u.auth_user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = deadline_window.deadline_id
      and u.auth_user_id = auth.uid()
  )
);

-- ========== reminder_policy ==========
drop policy if exists reminder_policy_all on reminder_policy;
create policy reminder_policy_all on reminder_policy
for all using (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = reminder_policy.deadline_id
      and u.auth_user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = reminder_policy.deadline_id
      and u.auth_user_id = auth.uid()
  )
);

-- ========== reminder ==========
drop policy if exists reminder_all on reminder;
create policy reminder_all on reminder
for all using (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = reminder.deadline_id
      and u.auth_user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = reminder.deadline_id
      and u.auth_user_id = auth.uid()
  )
);

-- ========== calendar_account ==========
drop policy if exists calendar_account_all on calendar_account;
create policy calendar_account_all on calendar_account
for all using (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = calendar_account.organisation_id
  )
) with check (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = calendar_account.organisation_id
  )
);

-- ========== calendar_event ==========
drop policy if exists calendar_event_all on calendar_event;
create policy calendar_event_all on calendar_event
for all using (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = calendar_event.deadline_id
      and u.auth_user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from deadline dl
    join document d on d.id = dl.document_id
    join app_user u on u.organisation_id = d.organisation_id
    where dl.id = calendar_event.deadline_id
      and u.auth_user_id = auth.uid()
  )
);

-- ========== email_inbound ==========
drop policy if exists email_inbound_all on email_inbound;
create policy email_inbound_all on email_inbound
for all using (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = email_inbound.organisation_id
  )
) with check (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = email_inbound.organisation_id
  )
);

-- ========== deadline_conflict ==========
drop policy if exists deadline_conflict_all on deadline_conflict;
create policy deadline_conflict_all on deadline_conflict
for all using (
  exists (
    select 1
    from document d
    join app_user u on u.organisation_id = d.organisation_id
    where d.id = deadline_conflict.document_id
      and u.auth_user_id = auth.uid()
  )
) with check (
  exists (
    select 1
    from document d
    join app_user u on u.organisation_id = d.organisation_id
    where d.id = deadline_conflict.document_id
      and u.auth_user_id = auth.uid()
  )
);

-- ========== audit_log (read-only für Mitglieder) ==========
drop policy if exists audit_log_select on audit_log;
create policy audit_log_select on audit_log
for select using (
  exists (
    select 1 from app_user u
    where u.auth_user_id = auth.uid()
      and u.organisation_id = audit_log.organisation_id
  )
);

-- =========================================================
-- 8) Optionale Defaults/Checks
-- =========================================================

-- Volltext-Spalte füllen (optional, z. B. in Worker)
-- update document set text_content = to_tsvector('german', coalesce(raw_text,''));

-- Helper-View: kommende Deadlines (30 Tage)
create or replace view v_upcoming_deadlines as
select
  d.id as deadline_id,
  d.document_id,
  doc.organisation_id,
  d.type,
  d.label,
  coalesce(dw.closes, d.absolute_due_date) as due_date
from deadline d
left join deadline_window dw on dw.deadline_id = d.id
join document doc on doc.id = d.document_id
where coalesce(dw.closes, d.absolute_due_date) between current_date and current_date + 30;

-- RLS auf View ist nicht nötig; View erbt Policies der Basistabellen.

-- =========================================================
-- Ende
-- =========================================================
