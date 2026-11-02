-- 会话消息是否被 bridge 截断（超过 maxTextChars）。
-- 带上这个标记是为了让手机能说清「你看的不是全文」，而不是假装内容就这么多。
alter table session_messages
  add column if not exists truncated boolean not null default false;

comment on column session_messages.truncated is
  'true = bridge 侧超出 maxTextChars 被截断，手机上的文本不是全文';
