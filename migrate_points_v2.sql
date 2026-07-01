-- ============================================================
-- ポイント制度 改訂版（2通貨 XP/コイン・50pt/Lv・新ストリーク・各種ボーナス）
-- 既存DBに上書き適用する。SupabaseのSQL Editorに貼って Run
-- ★Chromeのページ翻訳はオフにしてから実行すること（Monacoエディタが壊れるため）
-- 何度でも再実行できるよう IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT を使用
-- ============================================================

-- ------------------------------------------------------------
-- 1) students に 2通貨カラムとログインボーナス管理日を追加
--    xp   = 累積・減らない（レベルを決める）
--    coin = 残高・使うと減る（景品交換用。今回は消費UIなし）
-- ------------------------------------------------------------
alter table students add column if not exists xp   integer not null default 0;
alter table students add column if not exists coin integer not null default 0;
alter table students add column if not exists last_login_bonus_date date;

-- 旧 total_points を xp/コインへ移行（初回のみ。既にxpが動いていれば触らない）
update students
set xp = total_points, coin = total_points
where xp = 0 and total_points > 0;

-- ------------------------------------------------------------
-- 2) 補助テーブル
-- ------------------------------------------------------------
-- 全問正解ボーナス(+5)を「同一Unitにつき1日1回」に制限するための記録
create table if not exists daily_unit_perfect (
  student_id uuid not null references students(id) on delete cascade,
  subject_id uuid not null references subjects(id) on delete cascade,
  topic      text not null default '',   -- 例 Unit1/中3
  play_date  date not null,
  primary key (student_id, subject_id, topic, play_date)
);

-- Unit制覇(+5)は「一生に1回だけ」。制覇済みUnitを記録
create table if not exists unit_mastery (
  student_id  uuid not null references students(id) on delete cascade,
  subject_id  uuid not null references subjects(id) on delete cascade,
  topic       text not null default '',
  achieved_at timestamptz not null default now(),
  primary key (student_id, subject_id, topic)
);

-- ポイント履歴（XP/コインの入出金台帳。将来のコイン消費＝先生の引き換え待ちリストもここへ）
create table if not exists point_ledger (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id) on delete cascade,
  kind       text not null,            -- login/participation/perfect/mastery/streak/spend
  xp         integer not null default 0,
  coin       integer not null default 0,
  note       text not null default '',
  play_date  date not null default (now() at time zone 'Asia/Tokyo')::date,
  created_at timestamptz not null default now()
);
create index if not exists idx_ledger_student on point_ledger(student_id, created_at desc);

-- daily_sessions の「同日同Unitは1行だけ」制約を解除（再挑戦を許可するため）
alter table daily_sessions drop constraint if exists daily_sessions_uniq;
alter table daily_sessions drop constraint if exists daily_sessions_student_id_subject_id_play_date_key;

-- ------------------------------------------------------------
-- 3) RLS（新テーブル：本人は自分の行を読める。書き込みはRPC=SECURITY DEFINERのみ）
-- ------------------------------------------------------------
alter table daily_unit_perfect enable row level security;
alter table unit_mastery       enable row level security;
alter table point_ledger       enable row level security;

drop policy if exists dup_select_own on daily_unit_perfect;
create policy dup_select_own on daily_unit_perfect
  for select using (student_id = auth.uid());

drop policy if exists mastery_select_own on unit_mastery;
create policy mastery_select_own on unit_mastery
  for select using (student_id = auth.uid() or is_admin());

-- 履歴は本人＋先生（引き換え待ちリストを先生が見る）
drop policy if exists ledger_select on point_ledger;
create policy ledger_select on point_ledger
  for select using (student_id = auth.uid() or is_admin());

-- ------------------------------------------------------------
-- 4) レベル計算: 50ptごとに1レベル（Lv1=0〜49, Lv2=50〜99 …）
-- ------------------------------------------------------------
create or replace function calc_level(p_points integer)
returns integer
language sql
immutable
as $$
  select greatest(1, (p_points / 50) + 1);
$$;

-- ------------------------------------------------------------
-- 5) ログインボーナス: 1日1回 +1（XP・コイン同時）
-- ------------------------------------------------------------
create or replace function claim_login_bonus()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  v_today   date := (now() at time zone 'Asia/Tokyo')::date;
  v_stu     students%rowtype;
  v_awarded integer := 0;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;

  select * into v_stu from students where id = v_student for update;
  if not found then
    raise exception 'student profile not found';
  end if;

  if v_stu.last_login_bonus_date is distinct from v_today then
    update students set
      xp   = xp + 1,
      coin = coin + 1,
      total_points = xp + 1,          -- 旧カラムはxpと同期（admin互換）
      last_login_bonus_date = v_today
    where id = v_student
    returning xp, coin into v_stu.xp, v_stu.coin;

    insert into point_ledger (student_id, kind, xp, coin, note, play_date)
    values (v_student, 'login', 1, 1, 'ログインボーナス', v_today);
    v_awarded := 1;
  end if;

  return jsonb_build_object(
    'awarded', v_awarded,
    'xp_total', v_stu.xp,
    'coin_total', v_stu.coin,
    'level', calc_level(v_stu.xp)
  );
end;
$$;

-- ------------------------------------------------------------
-- 6) 採点＋加点RPC（改訂版）
--    p_answers 例: [{"question_id":"...","answer":"向上させる"}, ...]
--    加点は全てサーバー側で判定（改ざん防止）
-- ------------------------------------------------------------
create or replace function submit_daily_quiz(
  p_subject_slug text, p_answers jsonb, p_unit text default '', p_grade text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  v_subject uuid;
  v_topic   text := coalesce(p_unit, '');
  v_today   date := (now() at time zone 'Asia/Tokyo')::date;
  v_stu     students%rowtype;
  v_total   integer := 0;
  v_correct integer := 0;
  v_perfect boolean := false;
  v_mastered boolean := false;
  -- 加点の内訳
  v_part_pt    integer := 0;   -- 参加賞
  v_streak_pt  integer := 0;   -- 連続ボーナス
  v_perfect_pt integer := 0;   -- 全問正解
  v_mastery_pt integer := 0;   -- Unit制覇
  v_earned     integer := 0;   -- この回の合計(XP=コイン)
  v_new_streak integer;
  v_inc_days   integer := 0;
  v_level_before integer;
  v_level_after  integer;
  v_missing  integer;
  v_unit_cnt integer;
  v_ins      integer;
  a          jsonb;
  v_qid      uuid;
  v_ans      text;
  v_correct_ans text;
  v_is_ok    boolean;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;

  -- 1日1回判定・記録のキー: Unit（学年があれば付与）例 Unit1/中3
  if coalesce(p_grade,'') <> '' then
    v_topic := v_topic || '/' || p_grade;
  end if;

  select id into v_subject from subjects where slug = p_subject_slug and is_active = true;
  if v_subject is null then
    raise exception 'subject not available';
  end if;

  select * into v_stu from students where id = v_student for update;
  if not found then
    raise exception 'student profile not found';
  end if;

  v_level_before := calc_level(v_stu.xp);

  -- ---- 採点（サーバー側で判定）＋習熟更新 ----
  for a in select * from jsonb_array_elements(p_answers)
  loop
    v_qid := (a->>'question_id')::uuid;
    v_ans := a->>'answer';
    select answer into v_correct_ans from questions
      where id = v_qid and subject_id = v_subject;
    if v_correct_ans is null then
      continue;   -- 不正なIDは無視
    end if;
    v_total := v_total + 1;
    v_is_ok := (v_ans is not distinct from v_correct_ans);
    if v_is_ok then v_correct := v_correct + 1; end if;

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

  -- 有効な解答が無ければ何もしない
  if v_total = 0 then
    return jsonb_build_object(
      'correct', 0, 'total', 0, 'earned', 0, 'perfect', false, 'mastered', false,
      'participation_pt', 0, 'streak_pt', 0, 'perfect_pt', 0, 'mastery_pt', 0,
      'xp_total', v_stu.xp, 'coin_total', v_stu.coin,
      'current_streak', v_stu.current_streak, 'longest_streak', v_stu.longest_streak,
      'total_days', v_stu.total_days,
      'level_before', v_level_before, 'level_after', v_level_before
    );
  end if;

  v_perfect := (v_correct = v_total);

  -- ---- 参加賞(+1) と ストリーク：その日の最初の1セットだけ ----
  if v_stu.last_done_date = v_today then
    v_new_streak := v_stu.current_streak; v_inc_days := 0;   -- 今日はもう参加済み
  elsif v_stu.last_done_date = v_today - 1 then
    v_new_streak := v_stu.current_streak + 1; v_inc_days := 1;
  else
    v_new_streak := 1; v_inc_days := 1;
  end if;

  if v_inc_days = 1 then
    v_part_pt := 1;   -- 参加賞
    -- ストリーク・マイルストーン（3/7/14、以降30日ごと）
    if v_new_streak % 30 = 0 then
      v_streak_pt := 50;
    elsif v_new_streak = 14 then
      v_streak_pt := 30;
    elsif v_new_streak = 7 then
      v_streak_pt := 15;
    elsif v_new_streak = 3 then
      v_streak_pt := 5;
    end if;
  end if;

  -- ---- 全問正解(+5)：同一Unitにつき1日1回 ----
  if v_perfect and v_topic <> '' then
    insert into daily_unit_perfect (student_id, subject_id, topic, play_date)
    values (v_student, v_subject, v_topic, v_today)
    on conflict do nothing;
    get diagnostics v_ins = row_count;
    if v_ins = 1 then v_perfect_pt := 5; end if;
  end if;

  -- ---- Unit制覇(+5)：そのUnitの全単語を1度以上正解済み・一生に1回 ----
  if v_topic <> '' then
    select count(*) into v_unit_cnt
    from questions q
    where q.subject_id = v_subject and q.is_active = true
      and q.unit = p_unit
      and (coalesce(p_grade,'') = '' or q.grade = p_grade);

    if v_unit_cnt > 0 then
      select count(*) into v_missing
      from questions q
      where q.subject_id = v_subject and q.is_active = true
        and q.unit = p_unit
        and (coalesce(p_grade,'') = '' or q.grade = p_grade)
        and not exists (
          select 1 from student_question_progress sp
          where sp.student_id = v_student and sp.question_id = q.id and sp.correct_count > 0
        );
      if v_missing = 0 then
        insert into unit_mastery (student_id, subject_id, topic)
        values (v_student, v_subject, v_topic)
        on conflict do nothing;
        get diagnostics v_ins = row_count;
        if v_ins = 1 then v_mastery_pt := 5; v_mastered := true; end if;
      end if;
    end if;
  end if;

  v_earned := v_part_pt + v_streak_pt + v_perfect_pt + v_mastery_pt;

  -- ---- 生徒テーブル更新（XP・コイン同額同時） ----
  update students set
    xp             = xp + v_earned,
    coin           = coin + v_earned,
    total_points   = xp + v_earned,                      -- 旧カラムはxpに同期
    current_streak = v_new_streak,
    longest_streak = greatest(longest_streak, v_new_streak),
    total_days     = total_days + v_inc_days,
    last_done_date = v_today
  where id = v_student
  returning xp, coin into v_stu.xp, v_stu.coin;

  v_level_after := calc_level(v_stu.xp);

  -- ---- 台帳へ記録 ----
  if v_part_pt > 0 then
    insert into point_ledger (student_id, kind, xp, coin, note, play_date)
    values (v_student, 'participation', v_part_pt, v_part_pt, '参加賞', v_today);
  end if;
  if v_streak_pt > 0 then
    insert into point_ledger (student_id, kind, xp, coin, note, play_date)
    values (v_student, 'streak', v_streak_pt, v_streak_pt, v_new_streak || '日連続ボーナス', v_today);
  end if;
  if v_perfect_pt > 0 then
    insert into point_ledger (student_id, kind, xp, coin, note, play_date)
    values (v_student, 'perfect', v_perfect_pt, v_perfect_pt, '全問正解 ' || v_topic, v_today);
  end if;
  if v_mastery_pt > 0 then
    insert into point_ledger (student_id, kind, xp, coin, note, play_date)
    values (v_student, 'mastery', v_mastery_pt, v_mastery_pt, 'Unit制覇 ' || v_topic, v_today);
  end if;

  -- ---- セッション記録（ログ。再挑戦も毎回残す） ----
  insert into daily_sessions
    (student_id, subject_id, topic, play_date, total_count, correct_count, points_earned)
  values
    (v_student, v_subject, v_topic, v_today, v_total, v_correct, v_earned);

  return jsonb_build_object(
    'correct', v_correct, 'total', v_total, 'earned', v_earned,
    'perfect', v_perfect, 'mastered', v_mastered,
    'participation_pt', v_part_pt, 'streak_pt', v_streak_pt,
    'perfect_pt', v_perfect_pt, 'mastery_pt', v_mastery_pt,
    'xp_total', v_stu.xp, 'coin_total', v_stu.coin,
    'current_streak', v_new_streak, 'longest_streak', greatest(v_stu.longest_streak, v_new_streak),
    'total_days', v_stu.total_days + v_inc_days,
    'level_before', v_level_before, 'level_after', v_level_after
  );
end;
$$;

grant execute on function claim_login_bonus()                            to authenticated;
grant execute on function submit_daily_quiz(text, jsonb, text, text)     to authenticated;
grant execute on function calc_level(integer)                            to authenticated;
