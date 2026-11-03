-- 命令租约（P42）。
--
-- 为什么需要它：命令状态只有 bridge 会写。bridge 被硬杀 / 断网 / 机器休眠时，
-- Hub 上的命令会永远停在 delivered / running，手机上看起来「一直在执行」，
-- 只能人工 `npm run reconcile` 收尾（外部审计点名的第 5 条，见 docs/security-review.md）。
--
-- 现在三层兜底，职责不重叠：
--   1. bridge 的 reconcile（每 60s）：**看得到本机进程**，能区分「还活着」与「真的没了」；
--   2. 这里的租约（本迁移 + server/src/lease.js）：只看「执行侧还在不在续租」，
--      bridge 整个消失时也能收尾；
--   3. `npm run reconcile` / `npm run ps -- --clean`：人工排障。
--
-- 认领（pending → delivered）时写一次，bridge 每 30 秒 POST /commands/:id/heartbeat 续租，
-- 终态时清空。过期后 Hub 每 60 秒扫一次：running / delivered → failed: orphaned，
-- cancelling → cancelled（用户已经要求停，就不要再显示「失败」）。
alter table commands
  add column if not exists lease_expires_at timestamptz;

comment on column commands.lease_expires_at is
  '租约到期时间：bridge 认领 / 心跳时续期；过期由 Hub 回收成 failed: orphaned（cancelling 收成 cancelled）';

-- 只给「活状态」建部分索引：历史命令再多，扫描也只碰当前这批。
create index if not exists commands_lease_idx
  on commands (lease_expires_at)
  where status in ('delivered', 'running', 'cancelling');
