-- Cline Console Hub · 003 项目识别
-- 目的：会话列表按「项目」而不是「启动目录」分组。bridge 采集时向上找 .git / 构建标记，
-- 找不到且在家目录下就标记为 loose（散会话），不参与项目分组。

alter table sessions add column if not exists project      text;
alter table sessions add column if not exists project_root text;
alter table sessions add column if not exists project_kind text;

comment on column sessions.project is '项目名：从 workspace_root 向上找到 .git / 构建标记的目录名；散会话为空';
comment on column sessions.project_kind is 'project = 识别到项目根；loose = 家目录等散会话';

create index if not exists sessions_project_idx on sessions (project);