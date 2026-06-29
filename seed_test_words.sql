-- ============================================================
-- 動作確認用テストデータ: 英語・中1単語 20語
-- schema.sql を実行した後に、SQL Editor で Run
-- ============================================================
insert into questions (subject_id, unit, grade, format, prompt, answer)
select s.id, '中1単語', '中1', 'vocab', v.en, v.ja
from subjects s
cross join (values
  ('apple','りんご'),
  ('book','本'),
  ('cat','ねこ'),
  ('dog','いぬ'),
  ('school','学校'),
  ('teacher','先生'),
  ('friend','友だち'),
  ('water','水'),
  ('music','音楽'),
  ('science','理科'),
  ('morning','朝'),
  ('night','夜'),
  ('study','勉強する'),
  ('read','読む'),
  ('write','書く'),
  ('speak','話す'),
  ('listen','聞く'),
  ('run','走る'),
  ('eat','食べる'),
  ('sleep','ねむる')
) as v(en, ja)
where s.slug = 'english';
