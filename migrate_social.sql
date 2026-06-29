-- ============================================================
-- 社会の開通＋複数教科・分野対応マイグレーション
-- 既存DBに上書き適用する。SupabaseのSQL Editorに貼って Run
-- （Chromeのページ翻訳はオフにしてから実行すること）
-- ============================================================

-- 1) daily_sessions に分野(topic)を追加し、1日1回判定を
--    (生徒, 教科, 分野, 日付) 単位に変更
alter table daily_sessions add column if not exists topic text not null default '';
alter table daily_sessions drop constraint if exists daily_sessions_student_id_subject_id_play_date_key;
alter table daily_sessions drop constraint if exists daily_sessions_uniq;
alter table daily_sessions add constraint daily_sessions_uniq
  unique (student_id, subject_id, topic, play_date);

-- 2) 出題RPC（分野フィルタ p_unit を追加。choicesがあればそれを使う＝汎用4択対応）
drop function if exists get_daily_questions(text, integer);
create or replace function get_daily_questions(p_subject_slug text, p_limit integer default 10, p_unit text default '')
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
    select q.id, q.prompt, q.answer, q.choices
    from questions q
    left join student_question_progress p
      on p.question_id = q.id and p.student_id = v_student
    where q.subject_id = v_subject
      and q.is_active = true
      and (v_unit = '' or q.unit = v_unit)
      and (v_grade is null or q.grade = '' or q.grade = v_grade)
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
      -- 英単語型: 正解 + 他の意味からランダム3つ → シャッフル
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

-- 3) 採点RPC（分野ごと1日1回＋同日に複数教科/分野をやっても連続日数が壊れない）
drop function if exists submit_daily_quiz(text, jsonb);
create or replace function submit_daily_quiz(p_subject_slug text, p_answers jsonb, p_unit text default '')
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

  select id into v_subject from subjects where slug = p_subject_slug and is_active = true;
  if v_subject is null then
    raise exception 'subject not available';
  end if;

  select * into v_stu from students where id = v_student for update;
  if not found then
    raise exception 'student profile not found';
  end if;

  v_level_before := calc_level(v_stu.total_points);

  -- この教科×分野を今日すでにクリア済みか（=ポイントは入らない／練習）
  select true into v_already
  from daily_sessions
  where student_id = v_student and subject_id = v_subject and topic = v_topic and play_date = v_today;
  v_already := coalesce(v_already, false);

  -- 採点（サーバー側で判定）＋習熟更新
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

  -- すでに今日クリア済み（この教科×分野）→ ポイントなし
  if v_already then
    return jsonb_build_object(
      'correct', v_correct, 'total', v_total, 'points_earned', 0, 'already_done', true,
      'current_streak', v_stu.current_streak, 'total_days', v_stu.total_days,
      'level_before', v_level_before, 'level_after', v_level_before
    );
  end if;

  -- 連続日数は「その日の最初の1回」だけ加算（同日に別教科/分野をやっても据え置き）
  if v_stu.last_done_date = v_today then
    v_new_streak := v_stu.current_streak; v_inc_days := 0;
  elsif v_stu.last_done_date = v_today - 1 then
    v_new_streak := v_stu.current_streak + 1; v_inc_days := 1;
  else
    v_new_streak := 1; v_inc_days := 1;
  end if;

  -- ポイント：完了+10／正解+2。連続ボーナスは新しい日の最初の1回のみ
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

grant execute on function get_daily_questions(text, integer, text) to authenticated;
grant execute on function submit_daily_quiz(text, jsonb, text)     to authenticated;

-- 4) 社会を開通
update subjects set is_active = true where slug = 'social';

-- 5) 社会のサンプル問題（歴史・地理・公民／学年は問わず全員に出題）
--    すでに社会に問題がある場合は二重投入しないようガード
insert into questions (subject_id, unit, grade, format, prompt, answer, choices)
select s.id, v.unit, '', 'choice', v.prompt, v.answer, v.choices::jsonb
from subjects s
cross join (values
  ('歴史','鎌倉幕府を開いた人物は？','源頼朝','["源頼朝","足利尊氏","徳川家康","平清盛"]'),
  ('歴史','江戸幕府を開いた人物は？','徳川家康','["徳川家康","織田信長","豊臣秀吉","源頼朝"]'),
  ('歴史','室町幕府を開いた人物は？','足利尊氏','["足利尊氏","源頼朝","徳川家康","北条時宗"]'),
  ('歴史','関ヶ原の戦いが起きた年は？','1600年','["1600年","1582年","1467年","1185年"]'),
  ('歴史','日本に鉄砲を伝えたのは？','ポルトガル人','["ポルトガル人","オランダ人","イギリス人","中国人"]'),
  ('地理','日本で一番大きい湖は？','琵琶湖','["琵琶湖","霞ヶ浦","浜名湖","諏訪湖"]'),
  ('地理','日本で一番長い川は？','信濃川','["信濃川","利根川","石狩川","北上川"]'),
  ('地理','日本で一番高い山は？','富士山','["富士山","北岳","槍ヶ岳","白山"]'),
  ('地理','日本標準時の基準となる都市は？','明石市','["明石市","東京","京都","那覇市"]'),
  ('地理','三大都市圏に含まれないのは？','福岡','["福岡","東京","大阪","名古屋"]'),
  ('公民','日本国憲法の三大原則でないものは？','軍国主義','["軍国主義","国民主権","基本的人権の尊重","平和主義"]'),
  ('公民','日本の国会は何院制？','二院制','["二院制","一院制","三院制","四院制"]'),
  ('公民','選挙で投票できるのは何歳から？','18歳以上','["18歳以上","16歳以上","20歳以上","25歳以上"]'),
  ('公民','内閣の最高責任者は？','内閣総理大臣','["内閣総理大臣","天皇","最高裁長官","国会議長"]'),
  ('公民','三権分立の三権でないものは？','報道権','["報道権","立法権","行政権","司法権"]')
) as v(unit, prompt, answer, choices)
where s.slug = 'social'
  and not exists (select 1 from questions q2 where q2.subject_id = s.id);
