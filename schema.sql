-- ============================================================
-- SSG学習アプリ v1  Supabaseスキーマ
-- 実行方法: SupabaseダッシュボードのSQL Editorに貼って Run
-- 安全に何度でも再実行できるよう IF NOT EXISTS / CREATE OR REPLACE を使用
-- ============================================================

-- ------------------------------------------------------------
-- 0. 拡張
-- ------------------------------------------------------------
create extension if not exists "pgcrypto";  -- gen_random_uuid 用

-- ------------------------------------------------------------
-- 1. 管理者テーブル（塾長）
--    ここに入っている auth ユーザーだけが問題・生徒を編集できる
-- ------------------------------------------------------------
create table if not exists admins (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- 管理者判定ヘルパー
create or replace function is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from admins a where a.id = auth.uid());
$$;

-- ------------------------------------------------------------
-- 2. 生徒プロフィール
--    auth.users と 1:1。ポイント・連続・通算はここに集約。
--    ※ 生徒は自分の行を「読む」だけ。書き込みは必ずRPC経由。
-- ------------------------------------------------------------
create table if not exists students (
  id            uuid primary key references auth.users(id) on delete cascade,
  student_code  text unique not null,            -- 例 student07（ログインIDの素）
  display_name  text not null default '',         -- 例 たくみ
  grade         text not null default '中1',       -- 中1 / 中2 / 中3
  total_points  integer not null default 0,
  current_streak integer not null default 0,      -- 連続日数（切れたらリセット）
  longest_streak integer not null default 0,      -- 連続の最高記録
  total_days    integer not null default 0,       -- 通算やった日数（減らない）
  last_done_date date,                            -- 最後に10問完了した日（JST）
  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 3. 教科（メニューの6タイル）
-- ------------------------------------------------------------
create table if not exists subjects (
  id         uuid primary key default gen_random_uuid(),
  slug       text unique not null,   -- english / math / japanese / science / social / eiken
  name       text not null,          -- 英語 / 数学 ...
  sort_order integer not null default 0,
  is_active  boolean not null default false  -- 中身ができたら true（英語のみ true）
);

-- ------------------------------------------------------------
-- 4. 問題（汎用問題テーブル）
--    英単語もここに入る: format='vocab', prompt=英単語, answer=日本語の意味
--    将来の他教科・他形式もこの1テーブルに追加していく
-- ------------------------------------------------------------
create table if not exists questions (
  id          uuid primary key default gen_random_uuid(),
  subject_id  uuid not null references subjects(id) on delete cascade,
  unit        text not null default '',       -- 単元 例 中1単語
  grade       text not null default '',       -- 学年タグ 中1/中2/中3
  format      text not null default 'vocab',  -- vocab(4択) / choice / input / truefalse ...
  prompt      text not null,                  -- 問題文 / 英単語
  answer      text not null,                  -- 正解（サーバーだけが知る）
  choices     jsonb,                          -- 固定選択肢を持つ問題用（vocabはnull=自動生成）
  explanation text,                           -- 解説（任意）
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists idx_questions_subject on questions(subject_id, is_active);
create index if not exists idx_questions_grade   on questions(subject_id, grade);

-- ------------------------------------------------------------
-- 5. 生徒×問題の習熟状況（間違い優先の出題に使う）
-- ------------------------------------------------------------
create table if not exists student_question_progress (
  student_id    uuid not null references students(id) on delete cascade,
  question_id   uuid not null references questions(id) on delete cascade,
  correct_count integer not null default 0,
  wrong_count   integer not null default 0,
  last_result   boolean,                 -- 直近が正解だったか
  last_seen_date date,
  primary key (student_id, question_id)
);

-- ------------------------------------------------------------
-- 6. 日次セッション（1日1回判定＋ポイント履歴）
--    (student, subject, date) で一意 → 同じ日の二重加点を物理的に防ぐ
-- ------------------------------------------------------------
create table if not exists daily_sessions (
  id            uuid primary key default gen_random_uuid(),
  student_id    uuid not null references students(id) on delete cascade,
  subject_id    uuid not null references subjects(id) on delete cascade,
  play_date     date not null,           -- JSTの日付
  total_count   integer not null default 0,
  correct_count integer not null default 0,
  points_earned integer not null default 0,
  created_at    timestamptz not null default now(),
  unique (student_id, subject_id, play_date)
);
create index if not exists idx_sessions_student on daily_sessions(student_id, play_date);

-- ============================================================
-- 7. RLS（行レベルセキュリティ）
-- ============================================================
alter table admins                    enable row level security;
alter table students                  enable row level security;
alter table subjects                  enable row level security;
alter table questions                 enable row level security;
alter table student_question_progress enable row level security;
alter table daily_sessions            enable row level security;

-- admins: 本人だけ自分の行を確認できる（編集はダッシュボード/手動）
drop policy if exists admins_select_self on admins;
create policy admins_select_self on admins
  for select using (id = auth.uid());

-- students: 自分の行は読める / 管理者は全件読める。書き込みは管理者のみ（生徒はRPC経由）
drop policy if exists students_select on students;
create policy students_select on students
  for select using (id = auth.uid() or is_admin());
drop policy if exists students_admin_write on students;
create policy students_admin_write on students
  for all using (is_admin()) with check (is_admin());

-- subjects: 全ログインユーザーが読める / 書き込みは管理者のみ
drop policy if exists subjects_select on subjects;
create policy subjects_select on subjects
  for select using (auth.role() = 'authenticated');
drop policy if exists subjects_admin_write on subjects;
create policy subjects_admin_write on subjects
  for all using (is_admin()) with check (is_admin());

-- questions: 全ログインユーザーが読める（※answer列の秘匿は出題RPC側で担保） / 書き込みは管理者
drop policy if exists questions_select on questions;
create policy questions_select on questions
  for select using (auth.role() = 'authenticated');
drop policy if exists questions_admin_write on questions;
create policy questions_admin_write on questions
  for all using (is_admin()) with check (is_admin());

-- progress: 自分の分だけ読める。書き込みはRPC（SECURITY DEFINER）経由のみ
drop policy if exists progress_select_own on student_question_progress;
create policy progress_select_own on student_question_progress
  for select using (student_id = auth.uid());

-- daily_sessions: 自分の分だけ読める / 管理者は全件。書き込みはRPC経由のみ
drop policy if exists sessions_select on daily_sessions;
create policy sessions_select on daily_sessions
  for select using (student_id = auth.uid() or is_admin());

-- ※ progress と daily_sessions に INSERT/UPDATE ポリシーを「あえて作らない」ことで、
--   生徒からの直接書き込みを全面禁止。加点は下のRPCだけが行う。

-- ============================================================
-- 8. レベル計算（200ptごとに1レベル、最低1）
-- ============================================================
create or replace function calc_level(p_points integer)
returns integer
language sql
immutable
as $$
  select greatest(1, (p_points / 200) + 1);
$$;

-- ============================================================
-- 9. 出題RPC: 今日の10問を取得（間違い優先・正解は返さない）
--    返り値: [{ "question_id": uuid, "prompt": "improve", "choices": ["向上させる", ...4つ] }, ...]
-- ============================================================
create or replace function get_daily_questions(p_subject_slug text, p_limit integer default 10)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  v_grade   text;
  v_subject uuid;
  v_result  jsonb := '[]'::jsonb;
  r         record;
  v_choices jsonb;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;

  select grade into v_grade from students where id = v_student;
  select id into v_subject from subjects where slug = p_subject_slug and is_active = true;
  if v_subject is null then
    raise exception 'subject not available';
  end if;

  -- 間違い優先で出題対象を選ぶ:
  -- 0=直近不正解, 1=未出題, 2=正解済み(復習) の順 + ランダム
  for r in
    select q.id, q.prompt, q.answer, q.choices
    from questions q
    left join student_question_progress p
      on p.question_id = q.id and p.student_id = v_student
    where q.subject_id = v_subject
      and q.is_active = true
      and (v_grade is null or q.grade = '' or q.grade = v_grade)
    order by
      (case when p.last_result is false then 0
            when p.student_id is null   then 1
            else 2 end),
      random()
    limit p_limit
  loop
    if r.choices is not null then
      -- 汎用4択型: 保存済みの選択肢をシャッフルして使う
      select coalesce(jsonb_agg(elem order by random()), '[]'::jsonb)
      into v_choices
      from jsonb_array_elements(r.choices) elem;
    else
      -- 英単語型: 正解 + 同教科・同学年の他の意味からランダム3つ → シャッフル
      -- ※ UNION直下で order by random() は不可 → 誤答の抽出をサブクエリ d に隔離
      select coalesce(jsonb_agg(x order by random()), '[]'::jsonb)
      into v_choices
      from (
        select r.answer as x
        union
        select d.answer as x
        from (
          select q2.answer
          from questions q2
          where q2.subject_id = v_subject
            and q2.id <> r.id
            and q2.answer <> r.answer
            and (v_grade is null or q2.grade = '' or q2.grade = v_grade)
          order by random()
          limit 3
        ) d
      ) c;
    end if;

    v_result := v_result || jsonb_build_object(
      'question_id', r.id,
      'prompt',      r.prompt,
      'choices',     v_choices
    );
  end loop;

  return v_result;
end;
$$;

-- ============================================================
-- 10. 採点＋加点RPC: 解答を受け取り、サーバー側で正誤判定して加点
--     p_answers 例: [{"question_id":"...uuid...","answer":"向上させる"}, ...]
--     返り値: { correct, total, points_earned, already_done,
--               current_streak, total_days, level_before, level_after }
-- ============================================================
create or replace function submit_daily_quiz(p_subject_slug text, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  v_subject uuid;
  v_today   date := (now() at time zone 'Asia/Tokyo')::date;
  v_stu     students%rowtype;
  v_total   integer := 0;
  v_correct integer := 0;
  v_points  integer := 0;
  v_bonus   integer := 0;
  v_already boolean := false;
  v_new_streak integer;
  v_level_before integer;
  v_level_after  integer;
  a         jsonb;
  v_qid     uuid;
  v_ans     text;
  v_correct_ans text;
  v_is_ok   boolean;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;

  select id into v_subject from subjects where slug = p_subject_slug and is_active = true;
  if v_subject is null then
    raise exception 'subject not available';
  end if;

  select * into v_stu from students where id = v_student for update;
  if not found then
    raise exception 'student profile not found';
  end if;

  v_level_before := calc_level(v_stu.total_points);

  -- 今日すでにこの教科をクリア済みか（=ポイントは入らない、練習扱い）
  select true into v_already
  from daily_sessions
  where student_id = v_student and subject_id = v_subject and play_date = v_today;
  v_already := coalesce(v_already, false);

  -- 採点（正誤はサーバーが判定。クライアントの自己申告は信用しない）
  for a in select * from jsonb_array_elements(p_answers)
  loop
    v_qid := (a->>'question_id')::uuid;
    v_ans := a->>'answer';
    select answer into v_correct_ans from questions
      where id = v_qid and subject_id = v_subject;
    if v_correct_ans is null then
      continue;  -- 不正なIDは無視
    end if;
    v_total := v_total + 1;
    v_is_ok := (v_ans is not distinct from v_correct_ans);
    if v_is_ok then v_correct := v_correct + 1; end if;

    -- 習熟状況を更新（練習でも学習記録は残す）
    insert into student_question_progress
      (student_id, question_id, correct_count, wrong_count, last_result, last_seen_date)
    values
      (v_student, v_qid, case when v_is_ok then 1 else 0 end,
       case when v_is_ok then 0 else 1 end, v_is_ok, v_today)
    on conflict (student_id, question_id) do update set
      correct_count = student_question_progress.correct_count + case when v_is_ok then 1 else 0 end,
      wrong_count   = student_question_progress.wrong_count   + case when v_is_ok then 0 else 1 end,
      last_result   = v_is_ok,
      last_seen_date = v_today;
  end loop;

  -- すでに今日クリア済みなら、ここで終了（ポイント加算なし＝練習モード）
  if v_already then
    return jsonb_build_object(
      'correct', v_correct, 'total', v_total, 'points_earned', 0,
      'already_done', true,
      'current_streak', v_stu.current_streak, 'total_days', v_stu.total_days,
      'level_before', v_level_before, 'level_after', v_level_before
    );
  end if;

  -- ---- 初回クリア: 連続日数を計算 ----
  if v_stu.last_done_date = v_today - 1 then
    v_new_streak := v_stu.current_streak + 1;   -- 昨日もやった → 継続
  else
    v_new_streak := 1;                          -- 間が空いた → リセット
  end if;

  -- ---- ポイント計算 ----
  v_points := 10 + (v_correct * 2);             -- 完了+10 / 正解1問+2
  if v_new_streak % 7 = 0 then                  -- 7日連続ごとに +30
    v_bonus := 30;
  elsif v_new_streak = 3 then                   -- 3日連続で +10
    v_bonus := 10;
  end if;
  v_points := v_points + v_bonus;

  -- ---- 生徒テーブル更新 ----
  update students set
    total_points  = total_points + v_points,
    current_streak = v_new_streak,
    longest_streak = greatest(longest_streak, v_new_streak),
    total_days    = total_days + 1,
    last_done_date = v_today
  where id = v_student
  returning total_points into v_stu.total_points;

  v_level_after := calc_level(v_stu.total_points);

  -- ---- 日次セッション記録（一意制約で二重加点を防止） ----
  insert into daily_sessions
    (student_id, subject_id, play_date, total_count, correct_count, points_earned)
  values
    (v_student, v_subject, v_today, v_total, v_correct, v_points);

  return jsonb_build_object(
    'correct', v_correct, 'total', v_total, 'points_earned', v_points,
    'streak_bonus', v_bonus, 'already_done', false,
    'current_streak', v_new_streak, 'total_days', v_stu.total_days,
    'level_before', v_level_before, 'level_after', v_level_after
  );
end;
$$;

-- 生徒（authenticated）がRPCを呼べるように
grant execute on function get_daily_questions(text, integer) to authenticated;
grant execute on function submit_daily_quiz(text, jsonb)     to authenticated;

-- ============================================================
-- 11. 初期データ: 6教科（英語のみ is_active=true）
-- ============================================================
insert into subjects (slug, name, sort_order, is_active) values
  ('english',  '英語', 1, true),
  ('math',     '数学', 2, false),
  ('japanese', '国語', 3, false),
  ('science',  '理科', 4, false),
  ('social',   '社会', 5, false),
  ('eiken',    '英検', 6, false)
on conflict (slug) do nothing;
