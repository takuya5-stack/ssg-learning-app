-- ============================================================
-- 塾内ポイントランキング（今週=月曜0時JST〜の獲得XP順）
-- SQL Editorに貼って Run（Chromeのページ翻訳はオフで）
-- ============================================================
create or replace function get_weekly_ranking()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student    uuid := auth.uid();
  v_week_start timestamptz;
  v_result     jsonb := '[]'::jsonb;
  r            record;
  v_rank       integer := 0;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;

  -- 今週の始まり（月曜 0:00 JST）
  v_week_start := (date_trunc('week', (now() at time zone 'Asia/Tokyo'))) at time zone 'Asia/Tokyo';

  for r in
    select s.id, s.display_name, s.grade,
           coalesce(sum(pl.xp) filter (where pl.created_at >= v_week_start), 0)::integer as weekly_xp
    from students s
    left join point_ledger pl on pl.student_id = s.id
    where not exists (select 1 from admins a where a.id = s.id)   -- 管理者兼テスト用アカウントは除外
    group by s.id, s.display_name, s.grade
    having coalesce(sum(pl.xp) filter (where pl.created_at >= v_week_start), 0) > 0  -- 今週0ptの生徒は載せない
    order by weekly_xp desc, s.display_name asc
  loop
    v_rank := v_rank + 1;
    v_result := v_result || jsonb_build_object(
      'rank', v_rank,
      'display_name', r.display_name,
      'grade', r.grade,
      'weekly_xp', r.weekly_xp,
      'is_me', (r.id = v_student)
    );
  end loop;

  return v_result;
end;
$$;

grant execute on function get_weekly_ranking() to authenticated;
