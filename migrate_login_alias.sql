-- ============================================================
-- ログインIDのカスタム表示に対応（例: student01 → SSG01）
-- 実際のSupabase Auth側のメールアドレス(studentNN@ssg.local)は変えず、
-- ログイン画面に入力された表示ID(students.student_code)から
-- 認証用メールを引くRPCを追加する。生徒の見た目のIDだけ自由に変えられる。
-- SQL Editorに貼って Run（Chromeのページ翻訳はオフで）
-- ============================================================
create or replace function get_login_email(p_code text)
returns text
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.email
  from students s
  join auth.users u on u.id = s.id
  where lower(trim(s.student_code)) = lower(trim(p_code))
  limit 1;
$$;

-- ログイン前（未認証）でも呼べるように anon にも許可
grant execute on function get_login_email(text) to anon, authenticated;
