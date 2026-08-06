-- ============================================================
-- 在籍/退塾フラグ（退塾した生徒はランキングや配布対象から外す。記録は消さない）
-- SQL Editorに貼って Run（Chromeのページ翻訳はオフで）
-- ============================================================
alter table students add column if not exists is_enrolled boolean not null default true;

-- 退塾した生徒をここで false に（今後増えたら同じように1行足す）
update students set is_enrolled = false where student_code = 'SSG10';   -- はるか（退塾）

-- ランキング：在籍中かつ今週ポイントがある生徒だけ
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

  v_week_start := (date_trunc('week', (now() at time zone 'Asia/Tokyo'))) at time zone 'Asia/Tokyo';

  for r in
    select s.id, s.display_name, s.grade,
           coalesce(sum(pl.xp) filter (where pl.created_at >= v_week_start), 0)::integer as weekly_xp
    from students s
    left join point_ledger pl on pl.student_id = s.id
    where not exists (select 1 from admins a where a.id = s.id)   -- 管理者兼テスト用アカウントは除外
      and s.is_enrolled                                            -- 退塾した生徒は除外
    group by s.id, s.display_name, s.grade
    having coalesce(sum(pl.xp) filter (where pl.created_at >= v_week_start), 0) > 0  -- 今週0ptは載せない
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
