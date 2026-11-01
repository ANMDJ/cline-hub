-- Cline Console Hub · 002 消息流
-- 目标：会话详情不再只有「最后一条回复」，而是完整对话；完成通知能直接跳到会话。
-- 幂等：迁移框架按文件名只跑一次，但每条 DDL 仍然写成可重复执行的形式。

-- ------------------------------------------------------- hooks：关联会话
-- 没有它，动态页的「已完成」卡片只能看，点不进去。
alter table hooks add column if not exists session_id text;

create index if not exists hooks_session_idx
  on hooks (device_id, session_id)
  where session_id is not null;

-- ---------------------------------------------------- commands：续哪个会话
-- App 在会话详情里发消息时带上 sessionId，bridge 用 `cline --id` 接续原会话。
alter table commands add column if not exists session_id text;

-- ------------------------------------------------------------ session_messages
create table if not exists session_messages (
  device_id   text not null references clients(id) on delete cascade,
  session_id  text not null,
  message_id  text not null,
  seq         integer not null default 0,
  role        text not null default 'assistant',
  kind        text not null default 'text',
  text        text not null default '',
  tool        text,
  ts          timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (device_id, session_id, message_id)
);

comment on table session_messages is '逐条对话：user/assistant 正文 + 白名单工具的调用过程';
comment on column session_messages.kind is 'text = 正文；command = 工具调用（命令过程）';

-- 详情页按 seq 升序取；seq 来自 messages.json 里的顺序，跨批次也不会乱。
create index if not exists session_messages_order_idx
  on session_messages (device_id, session_id, seq);
