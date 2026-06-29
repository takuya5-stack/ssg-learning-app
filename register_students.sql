-- ============================================================
-- 生徒プロフィール一括登録
-- 前提: 先に Authentication で各 studentNN@ssg.local の
--       認証ユーザー(+PIN)を作成しておくこと
-- 認証ユーザーが存在する生徒だけ登録される（join）。再実行も安全（do nothing）
-- ============================================================
insert into students (id, student_code, display_name, grade)
select u.id, v.code, v.name, v.grade
from auth.users u
join (values
  ('student01@ssg.local','student01','樹','中1'),
  ('student02@ssg.local','student02','和己','中2'),
  ('student03@ssg.local','student03','吏絆','中2'),
  ('student04@ssg.local','student04','梨香子','中3'),
  ('student05@ssg.local','student05','かりん','中3'),
  ('student06@ssg.local','student06','ゆうり','高1'),
  ('student08@ssg.local','student08','りん','高1'),
  ('student09@ssg.local','student09','さくと','高1')
) as v(email, code, name, grade) on u.email = v.email
on conflict (id) do nothing;
