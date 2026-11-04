-- 执行前拒绝标记（P49，ADR-62）。
--
-- 背景：`cmd_e48d2ee78e0e` 带了本机不存在的目录，bridge 连 cline 都没启动，
-- 但 Hub 上只有 `status = failed` + 一段 errorText，手机看起来和「跑完失败」
-- 一模一样；排查时还会误以为是 App 漏传了 workspace。
--
-- 为什么不新增状态：`failed` 已经贯穿 Hub 的状态机、租约回收、App 的
-- `_terminalStatuses` / 通知 / 筛选。新增 `rejected` 要动四层契约与历史数据，
-- 收益只是 UI 文案；用两个附加字段就能表达同一件事。
--
-- 语义：
--   rejected_before_start = true  → 这条命令**没有 spawn 任何进程**；
--   rejected_reason               → 机器可读原因（App 映射成人话），
--                                    例如 workspace_missing / mode_not_allowed。
-- 两个字段都只增不减（bridge 后续补报 running 也不会清掉标记）。
alter table commands
  add column if not exists rejected_before_start boolean not null default false,
  add column if not exists rejected_reason text;

comment on column commands.rejected_before_start is
  '执行前被拒：bridge 没有 spawn 任何进程（目录不存在 / 模式不允许 / 白名单 / 附件失败）；status 仍是 failed';

comment on column commands.rejected_reason is
  '执行前拒绝的原因码：workspace_missing / workspace_not_allowed / mode_not_allowed / template_missing / attachment_failed';
