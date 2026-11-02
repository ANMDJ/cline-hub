-- 「选择题」的选项（Cline ask_question 的 options 数组）。
-- 单独一列而不是塞进 text：选项要渲染成按钮，塞文本里客户端只能靠正则猜。
alter table session_messages
  add column if not exists options jsonb not null default '[]'::jsonb;

comment on column session_messages.options is
  'kind=question 时的可选项数组；其他 kind 为空数组';
