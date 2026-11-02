-- 远程命令的「进程身份」：手机上能指到具体进程，本机能安全地只杀这一条。
--
-- 只存 pid 不够：Windows 会复用 PID（bridge 重启、原进程退出后 pid 很快被别的进程拿到），
-- 所以必须成对存「pid + 进程启动时间」。任何按 pid 杀进程之前都要双重核对，
-- 本机侧由 bridge 的登记文件 + `npm run ps` 完成（见 ADR-33）。
alter table commands
  add column if not exists pid            integer,
  add column if not exists pid_started_at timestamptz,
  add column if not exists runner         text;

comment on column commands.pid is
  '执行这条命令的子进程 PID（bridge spawn 成功立刻上报；未开始/已结束为 null）';
comment on column commands.pid_started_at is
  '子进程启动时间（bridge 本地时钟，与 pid 成对使用）；没有它不得按 pid 杀进程';
comment on column commands.runner is
  '实际执行器：cline / shell';
