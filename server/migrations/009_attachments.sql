-- 手机端「发送文件 / 图片」到电脑（P38）。
--
-- 为什么要落库而不是落磁盘：
--   * Hub 跑在 Docker 里，宿主机没有可信的持久目录挂载；写进 Postgres 的 bytea
--     跟着数据库一起备份 / 迁移，不用再维护一个 volume 与清理任务；
--   * 附件与命令是「一次性」的：bridge 领取命令后立刻下载到本机临时目录，
--     Hub 侧只保留最近的历史，删 clients 时级联清掉。
-- 大小上限由 HUB_MAX_ATTACHMENT_BYTES 控制（默认 8 MB，见 server/src/env.js）。
create table if not exists attachments (
  id          text primary key,
  -- 归属设备：device token 只能下载自己那台的附件（与 ADR-43 的读隔离一致）
  device_id   text not null references clients(id) on delete cascade,
  name        text not null,
  mime_type   text not null,
  byte_size   integer not null,
  -- 同一台设备 + 同名 + 同内容直接复用，避免手机连点两次堆两份一模一样的大文件
  sha256      text not null,
  data        bytea not null,
  uploaded_by text,
  created_at  timestamptz not null default now()
);

comment on table attachments is
  'App 发给电脑的附件（文件 / 图片）；bridge 领取命令后按 attachment_id 下载到本机';
comment on column attachments.sha256 is
  '内容哈希：同设备同名同哈希复用一条记录，不重复存储';

create index if not exists attachments_device_idx
  on attachments (device_id, created_at desc);

-- 命令只存引用：附件内容不参与命令列表查询（列表仍然不返回大字段，ADR-2）。
alter table commands
  add column if not exists attachment_id text references attachments(id) on delete set null;

comment on column commands.attachment_id is
  '这条命令携带的附件；bridge 会先下载到本机再把路径写进 prompt';

create index if not exists commands_attachment_idx
  on commands (attachment_id)
  where attachment_id is not null;
