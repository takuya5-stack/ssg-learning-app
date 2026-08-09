-- ============================================================
-- アバター（きせかえ）を追加する
--  ① students.avatar … いま着ているものを持つ jsonb
--  ② shop_items      … 商品カタログ（値段はサーバー側で持つ＝改ざん防止）
--  ③ student_items   … 誰が何を持っているか
--  ④ RPC get_avatar_shop / buy_item / set_avatar
--  ⑤ get_weekly_ranking がアバターも返すように（ランキングに顔を並べるため）
-- 実行方法: SupabaseダッシュボードのSQL Editorに貼って Run（Chromeのページ翻訳はオフで）
-- 何度実行しても同じ結果になります
-- ============================================================

-- ① 着ているもの
alter table students add column if not exists avatar jsonb not null default '{}'::jsonb;

-- ② 商品カタログ
create table if not exists shop_items (
  id         text primary key,
  slot       text not null,             -- skin/hair/face/body/hat/acc/bg
  name       text not null,
  price      integer not null default 0,-- 0 = 最初から持っている
  sort_order integer not null default 0,
  is_active  boolean not null default true
);
alter table shop_items enable row level security;
drop policy if exists shop_select on shop_items;
create policy shop_select on shop_items
  for select using (auth.role() = 'authenticated');
drop policy if exists shop_admin_write on shop_items;
create policy shop_admin_write on shop_items
  for all using (is_admin()) with check (is_admin());

-- ③ 持ち物（書き込みはRPC経由のみ。生徒は自分の分だけ読める）
create table if not exists student_items (
  student_id uuid not null references students(id) on delete cascade,
  item_id    text not null references shop_items(id) on delete cascade,
  bought_at  timestamptz not null default now(),
  primary key (student_id, item_id)
);
alter table student_items enable row level security;
drop policy if exists sitems_select_own on student_items;
create policy sitems_select_own on student_items
  for select using (student_id = auth.uid() or is_admin());

-- カタログ投入（アイテムを足すときはここに行を足すか tools/register_shop.mjs を使う）
insert into shop_items (id, slot, name, price, sort_order) values
  ('skin1', 'skin', 'はだ1', 0, 1),
  ('skin2', 'skin', 'はだ2', 0, 2),
  ('skin3', 'skin', 'はだ3', 0, 3),
  ('hair_short', 'hair', 'ショート', 0, 4),
  ('hair_bob', 'hair', 'ボブ', 0, 5),
  ('hair_long', 'hair', 'ロング', 10, 6),
  ('hair_spiky', 'hair', 'ツンツン', 10, 7),
  ('hair_bun', 'hair', 'おだんご', 10, 8),
  ('hair_pony', 'hair', 'ポニーテール', 10, 9),
  ('hair_twin', 'hair', 'ツインテール', 10, 10),
  ('hair_gold', 'hair', 'きんぱつ', 10, 11),
  ('face_normal', 'face', 'ふつう', 0, 12),
  ('face_smile', 'face', 'にっこり', 0, 13),
  ('face_wink', 'face', 'ウインク', 10, 14),
  ('face_star', 'face', 'キラキラ', 10, 15),
  ('face_cool', 'face', 'クール', 10, 16),
  ('face_ganbaru', 'face', 'やるき', 10, 17),
  ('body_gym', 'body', 'たいそうぎ', 0, 18),
  ('body_tee', 'body', 'Tシャツ', 10, 19),
  ('body_hoodie', 'body', 'パーカー', 10, 20),
  ('body_sweater', 'body', 'セーター', 10, 21),
  ('body_jersey', 'body', 'ジャージ', 10, 22),
  ('body_uniform', 'body', 'せいふく', 10, 23),
  ('body_cape', 'body', 'マント', 10, 24),
  ('hat_none', 'hat', 'なし', 0, 25),
  ('hat_cap', 'hat', 'キャップ', 10, 26),
  ('hat_ribbon', 'hat', 'リボン', 10, 27),
  ('hat_beanie', 'hat', 'ニットぼう', 10, 28),
  ('hat_hachimaki', 'hat', 'はちまき', 10, 29),
  ('hat_headphone', 'hat', 'ヘッドホン', 10, 30),
  ('hat_crown', 'hat', 'おうかん', 10, 31),
  ('acc_none', 'acc', 'なし', 0, 32),
  ('acc_glasses', 'acc', 'メガネ', 10, 33),
  ('acc_sun', 'acc', 'サングラス', 10, 34),
  ('acc_mask', 'acc', 'マスク', 10, 35),
  ('acc_muffler', 'acc', 'マフラー', 10, 36),
  ('acc_bandaid', 'acc', 'ばんそうこう', 10, 37),
  ('acc_flower', 'acc', 'おはな', 10, 38),
  ('bg_cream', 'bg', 'クリーム', 0, 39),
  ('bg_sky', 'bg', 'そら', 10, 40),
  ('bg_sakura', 'bg', 'さくら', 10, 41),
  ('bg_forest', 'bg', 'もり', 10, 42),
  ('bg_night', 'bg', 'よぞら', 10, 43),
  ('bg_rainbow', 'bg', 'にじ', 10, 44),
  ('bg_gold', 'bg', 'きんぴか', 10, 45)
on conflict (id) do update set
  slot = excluded.slot, name = excluded.name,
  price = excluded.price, sort_order = excluded.sort_order, is_active = true;

-- ④-1 きせかえ画面に必要なものを一度に返す
create or replace function get_avatar_shop()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;
  return jsonb_build_object(
    'coin',   (select coin   from students where id = v_student),
    'avatar', (select avatar from students where id = v_student),
    'items',  (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', si.id, 'slot', si.slot, 'name', si.name, 'price', si.price,
                  'owned', (si.price = 0 or exists (
                     select 1 from student_items x
                     where x.student_id = v_student and x.item_id = si.id))
                ) order by si.sort_order), '[]'::jsonb)
              from shop_items si where si.is_active)
  );
end;
$$;
grant execute on function get_avatar_shop() to authenticated;

-- ④-2 買う（値段はサーバーのカタログから読む。コインだけ減りXPは変わらない）
create or replace function buy_item(p_item_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  v_price   integer;
  v_name    text;
  v_coin    integer;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;
  select price, name into v_price, v_name from shop_items where id = p_item_id and is_active;
  if v_price is null then
    raise exception 'item not found';
  end if;
  if exists (select 1 from student_items where student_id = v_student and item_id = p_item_id) then
    raise exception 'already owned';
  end if;
  select coin into v_coin from students where id = v_student;
  if v_coin < v_price then
    raise exception 'not enough coin';
  end if;

  update students set coin = coin - v_price where id = v_student;
  insert into student_items (student_id, item_id) values (v_student, p_item_id);
  insert into point_ledger (student_id, kind, xp, coin, note)
  values (v_student, 'spend', 0, -v_price, 'アバター: ' || v_name);

  return jsonb_build_object('ok', true, 'coin', v_coin - v_price);
end;
$$;
grant execute on function buy_item(text) to authenticated;

-- ④-3 着替える（持っていないものは着られない）
create or replace function set_avatar(p_avatar jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid := auth.uid();
  k text;
  v text;
begin
  if v_student is null then
    raise exception 'not authenticated';
  end if;
  for k, v in select key, value #>> '{}' from jsonb_each(p_avatar) loop
    if not exists (
      select 1 from shop_items si
      where si.id = v and si.slot = k and si.is_active
        and (si.price = 0 or exists (
              select 1 from student_items x
              where x.student_id = v_student and x.item_id = si.id))
    ) then
      raise exception 'item not owned: %', v;
    end if;
  end loop;

  update students set avatar = p_avatar where id = v_student;
  return jsonb_build_object('ok', true, 'avatar', p_avatar);
end;
$$;
grant execute on function set_avatar(jsonb) to authenticated;

-- ⑤ ランキングにアバターを載せる（migrate_enrollment.sql の内容に avatar を足しただけ）
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
    select s.id, s.display_name, s.grade, s.avatar,
           coalesce(sum(pl.xp) filter (where pl.created_at >= v_week_start), 0)::integer as weekly_xp
    from students s
    left join point_ledger pl on pl.student_id = s.id
    where not exists (select 1 from admins a where a.id = s.id)   -- 管理者兼テスト用アカウントは除外
      and s.is_enrolled                                            -- 退塾した生徒は除外
    group by s.id, s.display_name, s.grade, s.avatar
    having coalesce(sum(pl.xp) filter (where pl.created_at >= v_week_start), 0) > 0
    order by weekly_xp desc, s.display_name asc
  loop
    v_rank := v_rank + 1;
    v_result := v_result || jsonb_build_object(
      'rank', v_rank,
      'display_name', r.display_name,
      'grade', r.grade,
      'avatar', r.avatar,
      'weekly_xp', r.weekly_xp,
      'is_me', (r.id = v_student)
    );
  end loop;

  return v_result;
end;
$$;
grant execute on function get_weekly_ranking() to authenticated;
