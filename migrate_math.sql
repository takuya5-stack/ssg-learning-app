-- ============================================================
-- 数学（中3の計算）を開通する
--  ① subjects の math を is_active=true に（出題RPCが教科を見つけられるようにする）
--  ② get_daily_questions が explanation（解説）も返すようにする
--     → 間違えたときに「なぜそうなるか」を画面に出すため。数学以外は解説nullなので影響なし
-- 実行方法: SupabaseダッシュボードのSQL Editorに貼って Run（Chromeのページ翻訳はオフで）
-- ============================================================

-- ① 数学を開通
update subjects set is_active = true where slug = 'math';

-- ② 出題RPCに explanation を追加（migrate_question_image.sql の内容に1行足しただけ）
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
    select q.id, q.prompt, q.answer, q.choices, q.unit, q.grade, q.image_url, q.explanation
    from questions q
    left join student_question_progress p
      on p.question_id = q.id and p.student_id = v_student
    where q.subject_id = v_subject
      and q.is_active = true
      and (v_unit = '' or q.unit = v_unit)
      and (
        case
          when v_pgrade <> '' then q.grade = v_pgrade
          else (v_grade is null or q.grade = '' or q.grade = v_grade)
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
      select coalesce(jsonb_agg(elem order by random()), '[]'::jsonb)
      into v_choices
      from jsonb_array_elements(r.choices) elem;
    else
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
      'question_id',  r.id,
      'prompt',       r.prompt,
      'answer',       r.answer,
      'image',        r.image_url,
      'explanation',  r.explanation,   -- ★ 解説（無ければnull）
      'choices',      v_choices
    );
  end loop;

  return v_result;
end;
$$;

grant execute on function get_daily_questions(text, integer, text, text) to authenticated;
