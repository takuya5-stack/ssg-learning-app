-- ============================================================
-- migrate_score_bonus.sql
-- 追加ルール: 1回のクイズで「6問以上正答」したら 毎回 +1点(XP=コイン各+1)
--   ・1日1回/Unit1回などの制限なし（毎回もらえる）
--   ・既存の 参加賞/連続/全問正解/Unit制覇 とは別枠で加算
-- submit_daily_quiz を丸ごと create or replace で置き換える（migrate_points_v2.sql の後に流す）
-- Supabaseダッシュボード → SQL Editor に貼って Run。翻訳はオフで。
-- ============================================================
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
  v_score_pt   integer := 0;   -- ★6問以上正答ボーナス(毎回)
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
      'participation_pt', 0, 'streak_pt', 0, 'perfect_pt', 0, 'mastery_pt', 0, 'score_pt', 0,
      'xp_total', v_stu.xp, 'coin_total', v_stu.coin,
      'current_streak', v_stu.current_streak, 'longest_streak', v_stu.longest_streak,
      'total_days', v_stu.total_days,
      'level_before', v_level_before, 'level_after', v_level_before
    );
  end if;

  v_perfect := (v_correct = v_total);

  -- ---- ★6問以上正答(+1)：毎回（1日/Unitの制限なし） ----
  if v_correct >= 6 then
    v_score_pt := 1;
  end if;

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

  v_earned := v_part_pt + v_streak_pt + v_perfect_pt + v_mastery_pt + v_score_pt;

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
  if v_score_pt > 0 then
    insert into point_ledger (student_id, kind, xp, coin, note, play_date)
    values (v_student, 'score', v_score_pt, v_score_pt, '6問以上正答ボーナス', v_today);
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
    'perfect_pt', v_perfect_pt, 'mastery_pt', v_mastery_pt, 'score_pt', v_score_pt,
    'xp_total', v_stu.xp, 'coin_total', v_stu.coin,
    'current_streak', v_new_streak, 'longest_streak', greatest(v_stu.longest_streak, v_new_streak),
    'total_days', v_stu.total_days + v_inc_days,
    'level_before', v_level_before, 'level_after', v_level_after
  );
end;
$$;

grant execute on function submit_daily_quiz(text, jsonb, text, text) to authenticated;
