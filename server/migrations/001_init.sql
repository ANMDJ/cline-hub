-- Cline Console Hub · 初始表结构
-- 幂等：可重复执行。所有时间列都用 timestamptz（bridge 上传 ISO8601 字符串）。

create table if not exists clients (
  id            text primary key,
  name          text not null,
  role          text not null check (role in ('device', 'app')),
  token_hash    text not null unique,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz
);

comment on table clients is '接入方：device = Windows bridge，app = 手机端';

-- ---------------------------------------------------------------- sessions

create table if not exists sessions (
  device_id         text not null references clients(id) on delete cascade,
  session_id        text not null,
  workspace         text,
  workspace_root    text,
  source            text,
  status            text,
  exit_code         integer,
  provider          text,
  model             text,
  started_at        timestamptz,
  ended_at          timestamptz,
  updated_at        timestamptz,
  prompt            text,
  user_prompt       text,
  result_ok         boolean not null default false,
  result_error      text,
  result_text       text,
  result_truncated  boolean not null default false,
  commands          jsonb not null default '[]'::jsonb,
  metrics           jsonb not null default '{}'::jsonb,
  collected_at      timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  updated_row_at    timestamptz not null default now(),
  primary key (device_id, session_id)
);

create index if not exists sessions_recent_idx
  on sessions (device_id, coalesce(ended_at, started_at, updated_at) desc nulls last);

create index if not exists sessions_workspace_idx
  on sessions (workspace);

-- ---------------------------------------------------------------- hooks

create table if not exists hooks (
  id          bigserial primary key,
  device_id   text not null references clients(id) on delete cascade,
  event       text not null default '',
  workspace   text,
  title       text,
  body        text,
  payload     jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now()
);

create index if not exists hooks_recent_idx on hooks (id desc);

-- ---------------------------------------------------------------- commands

create table if not exists commands (
  id           text primary key,
  device_id    text not null references clients(id) on delete cascade,
  prompt       text not null,
  mode         text not null default 'plan' check (mode in ('plan', 'act', 'yolo')),
  workspace    text,
  status       text not null default 'pending'
               check (status in ('pending', 'delivered', 'running', 'done', 'failed', 'cancelled')),
  requested_by text,
  result_text  text,
  error_text   text,
  created_at   timestamptz not null default now(),
  delivered_at timestamptz,
  started_at   timestamptz,
  finished_at  timestamptz
);

create index if not exists commands_pending_idx
  on commands (device_id, created_at)
  where status in ('pending', 'delivered');
