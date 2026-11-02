-- 手机端取消命令（P14）。
--
-- 为什么要单独一列，而不是直接改 status：
--   * 排队中（pending / delivered）取消 → 直接 cancelled，bridge 还没 spawn，不用杀进程；
--   * 执行中（running）取消 → 先置 cancelling，等 bridge 按 commandId 精确杀进程树后
--     自己回写 cancelled。中间这段时间手机上要显示「取消中」，所以状态是有意义的一档。
-- 保留 cancel_requested_at 便于事后判断「这条是自己跑完的，还是被取消的」。
alter table commands
  add column if not exists cancel_requested_at timestamptz;

comment on column commands.cancel_requested_at is
  '手机端请求取消的时间；running → cancelling 时写入，bridge 停止执行进程后回写 cancelled';

-- bridge 每 5 秒按 (device_id, status=cancelling) 拉一次待取消命令，
-- 这个部分索引只覆盖 4 个「活状态」，不会随历史命令增长。
create index if not exists commands_active_by_device_idx
  on commands (device_id, status)
  where status in ('pending', 'delivered', 'running', 'cancelling');
