-- `cancelling` 是 P14 新增的「活状态」：命令还在跑，但手机端已经点了取消，
-- 等 bridge 杀掉执行进程后回写 `cancelled`。
--
-- 001 里的 `commands_status_check` 只列了 6 个值，直接 UPDATE 会 500
-- （new row for relation "commands" violates check constraint "commands_status_check"，
-- 2026-11-02 线上实测）。约束按「删了重建」的方式扩，重复执行也安全。
alter table commands drop constraint if exists commands_status_check;

alter table commands
  add constraint commands_status_check
  check (status in ('pending', 'delivered', 'running', 'cancelling', 'done', 'failed', 'cancelled'));

comment on column commands.status is
  'pending 排队 / delivered 已领取 / running 执行中 / cancelling 取消中 / done / failed / cancelled';
