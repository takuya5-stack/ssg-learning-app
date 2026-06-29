-- ============================================================
-- 英語を「分野(単語/文法/熟語/不規則動詞) × 学年(中1/中2/中3)」対応に
-- 学年は生徒が自由に選べる（p_grade で指定）
-- SQL Editorに貼って Run（Chromeのページ翻訳はオフで）
-- ============================================================

-- 1) 既存の英語単語(format=vocab)の単元を「単語」に統一（学年タグ中1はそのまま）
update questions
set unit = '単語'
where subject_id = (select id from subjects where slug = 'english')
  and format = 'vocab';

-- 2) 出題RPC: p_unit(分野) と p_grade(選んだ学年) で絞れるように
drop function if exists get_daily_questions(text, integer, text);
create or replace function get_daily_questions(
  p_subject_slug text, p_limit integer default 10, p_unit text default '', p_grade text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  v_grade   text;
  v_subject uuid;
  v_unit    text := coalesce(p_unit, '');
  v_pgrade  text := coalesce(p_grade, '');
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

  for r in
    select q.id, q.prompt, q.answer, q.choices, q.unit, q.grade
    from questions q
    left join student_question_progress p
      on p.question_id = q.id and p.student_id = v_student
    where q.subject_id = v_subject
      and q.is_active = true
      and (v_unit = '' or q.unit = v_unit)
      and (
        case
          when v_pgrade <> '' then q.grade = v_pgrade           -- 学年が指定された(英語)→その学年
          else (v_grade is null or q.grade = '' or q.grade = v_grade)  -- 未指定(社会など)→生徒の学年/全学年
        end
      )
    order by
      (case when p.last_result is false then 0
            when p.student_id is null   then 1
            else 2 end),
      random()
    limit p_limit
  loop
    if r.choices is not null then
      -- 汎用4択型: 保存済みの選択肢をシャッフル
      select coalesce(jsonb_agg(elem order by random()), '[]'::jsonb)
      into v_choices
      from jsonb_array_elements(r.choices) elem;
    else
      -- 英単語型: 正解 + 同じ分野・学年の他の答えからランダム3つ → シャッフル
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
            and q2.unit = r.unit
            and q2.grade = r.grade
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

-- 3) 採点RPC: p_grade も受け取り、1日1回判定のキー(topic)を「分野/学年」で構成
drop function if exists submit_daily_quiz(text, jsonb, text);
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
  v_points  integer := 0;
  v_bonus   integer := 0;
  v_already boolean := false;
  v_new_streak integer;
  v_inc_days   integer := 0;
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

  -- 1日1回判定キー: 分野/学年（学年指定があれば付ける）
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

  v_level_before := calc_level(v_stu.total_points);

  select true into v_already
  from daily_sessions
  where student_id = v_student and subject_id = v_subject and topic = v_topic and play_date = v_today;
  v_already := coalesce(v_already, false);

  for a in select * from jsonb_array_elements(p_answers)
  loop
    v_qid := (a->>'question_id')::uuid;
    v_ans := a->>'answer';
    select answer into v_correct_ans from questions
      where id = v_qid and subject_id = v_subject;
    if v_correct_ans is null then
      continue;
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

  if v_already then
    return jsonb_build_object(
      'correct', v_correct, 'total', v_total, 'points_earned', 0, 'already_done', true,
      'current_streak', v_stu.current_streak, 'total_days', v_stu.total_days,
      'level_before', v_level_before, 'level_after', v_level_before
    );
  end if;

  if v_stu.last_done_date = v_today then
    v_new_streak := v_stu.current_streak; v_inc_days := 0;
  elsif v_stu.last_done_date = v_today - 1 then
    v_new_streak := v_stu.current_streak + 1; v_inc_days := 1;
  else
    v_new_streak := 1; v_inc_days := 1;
  end if;

  v_points := 10 + (v_correct * 2);
  if v_inc_days = 1 then
    if v_new_streak % 7 = 0 then
      v_bonus := 30;
    elsif v_new_streak = 3 then
      v_bonus := 10;
    end if;
  end if;
  v_points := v_points + v_bonus;

  update students set
    total_points   = total_points + v_points,
    current_streak = v_new_streak,
    longest_streak = greatest(longest_streak, v_new_streak),
    total_days     = total_days + v_inc_days,
    last_done_date = v_today
  where id = v_student
  returning total_points into v_stu.total_points;

  v_level_after := calc_level(v_stu.total_points);

  insert into daily_sessions
    (student_id, subject_id, topic, play_date, total_count, correct_count, points_earned)
  values
    (v_student, v_subject, v_topic, v_today, v_total, v_correct, v_points);

  return jsonb_build_object(
    'correct', v_correct, 'total', v_total, 'points_earned', v_points,
    'streak_bonus', v_bonus, 'already_done', false,
    'current_streak', v_new_streak, 'total_days', v_stu.total_days + v_inc_days,
    'level_before', v_level_before, 'level_after', v_level_after
  );
end;
$$;

grant execute on function get_daily_questions(text, integer, text, text) to authenticated;
grant execute on function submit_daily_quiz(text, jsonb, text, text)     to authenticated;

-- 4) 新分野のサンプル（すべて中1）。文法=汎用4択、熟語/不規則動詞=英単語型(自動生成)
--    すでに同じ分野に問題があれば二重投入しないようガード
-- 4-1) 文法（中1・汎用4択）
insert into questions (subject_id, unit, grade, format, prompt, answer, choices)
select s.id, '文法', '中1', 'choice', v.prompt, v.answer, v.choices::jsonb
from subjects s
cross join (values
  ('I ___ to school every day.','go','["go","goes","going","went"]'),
  ('She ___ English very well.','speaks','["speaks","speak","speaking","spoke"]'),
  ('There ___ a cat on the table.','is','["is","are","am","be"]'),
  ('___ you like music?','Do','["Do","Does","Are","Is"]')
) as v(prompt, answer, choices)
where s.slug = 'english'
  and not exists (select 1 from questions q2 where q2.subject_id = s.id and q2.unit = '文法');

-- 4-2) 熟語（中1・英単語型）
insert into questions (subject_id, unit, grade, format, prompt, answer)
select s.id, '熟語', '中1', 'vocab', v.en, v.ja
from subjects s
cross join (values
  ('get up','起きる'),
  ('look at','〜を見る'),
  ('listen to','〜を聞く'),
  ('go to bed','寝る'),
  ('every day','毎日'),
  ('a lot of','たくさんの')
) as v(en, ja)
where s.slug = 'english'
  and not exists (select 1 from questions q2 where q2.subject_id = s.id and q2.unit = '熟語');

-- 4-3) 不規則動詞（中1・英単語型）
insert into questions (subject_id, unit, grade, format, prompt, answer)
select s.id, '不規則動詞', '中1', 'vocab', v.en, v.ja
from subjects s
cross join (values
  ('go の過去形は？','went'),
  ('eat の過去形は？','ate'),
  ('see の過去形は？','saw'),
  ('come の過去形は？','came'),
  ('take の過去形は？','took'),
  ('make の過去形は？','made')
) as v(en, ja)
where s.slug = 'english'
  and not exists (select 1 from questions q2 where q2.subject_id = s.id and q2.unit = '不規則動詞');
