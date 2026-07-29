-- student10 はるか（中2）をプロフィール登録
-- 前提: 先に Authentication で student10@ssg.local (PIN=123456, Auto Confirm ON) を作成しておくこと
insert into students (id, student_code, display_name, grade)
select u.id, 'student10', 'はるか', '中2'
from auth.users u
where u.email = 'student10@ssg.local'
on conflict (id) do nothing;
