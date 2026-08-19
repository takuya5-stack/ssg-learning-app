-- ============================================================
-- 総合（これまでの累計）ランキングを追加する
--   既存の get_weekly_ranking（今週ぶん）はそのまま。並べて使う
--   累計XPは students.xp をそのまま使う（xpは減らないので台帳を合計する必要がない）
-- 実行方法: SupabaseダッシュボードのSQL Editorに貼って Run（Chromeのページ翻訳はオフで）
-- 何度実行しても同じ結果になります
-- ============================================================

create or replace function get_total_ranking()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  v_result  jsonb := '[]'::jsonb;
  r         record;
  v_rank    integer := 0;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;

  for r in
    select s.id, s.display_name, s.grade, s.avatar, s.xp, s.total_days, s.longest_streak
    from students s
    where not exists (select 1 from admins a where a.id = s.id)   -- 管理者兼テスト用アカウントは除外
      and s.is_enrolled                                            -- 退塾した生徒は除外
      and s.xp > 0                                                 -- まだ0ptの生徒は載せない
                                                                   -- ※全員載せたいなら この行を消す
    order by s.xp desc, s.display_name asc
  loop
    v_rank := v_rank + 1;
    v_result := v_result || jsonb_build_object(
      'rank',           v_rank,
      'display_name',   r.display_name,
      'grade',          r.grade,
      'avatar',         r.avatar,
      'xp',             r.xp,
      'level',          calc_level(r.xp),
      'total_days',     r.total_days,
      'longest_streak', r.longest_streak,
      'is_me',          (r.id = v_student)
    );
  end loop;

  return v_result;
end;
$$;

grant execute on function get_total_ranking() to authenticated;
