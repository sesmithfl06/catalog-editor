-- Move teaser passages: long ones (over 300 characters) to Excerpts, short ones (300 characters or less) to Teasers.
-- Run once in Supabase → SQL Editor (paste the whole file, then Run). Safe to run again: a second run changes nothing.
-- An excerpt is several paragraphs; a teaser is a couple of lines (300 characters or less) for a marketing snippet.
--
-- 1. Each marketing_copy Teaser row over 300 characters is split into its passages (at "Teaser #2", "#3 (chapter 4)" lines).
--    A passage already in editions.excerpts of the same book is skipped; a longer version of an excerpt replaces it;
--    any other long passage is added at the end of editions.excerpts; a short one stays a Teaser. Then the long row is deleted.
-- 2. Each piece of editions.excerpts of 300 characters or less becomes a Teaser row (unless the book already has that teaser).
-- 3. The labels in editions.excerpts ("Teaser #1:", "#2", "3", "Teaser 4 mid ch 7") become "Excerpt 1", "Excerpt 2"…,
--    numbered in order and keeping any note ("Excerpt 2 (chapter 3)", "Excerpt 4: mid ch 7"). Heading lines
--    ("Teasers:", "Excerpts") go.
-- 4. Every change is logged in change_log. Added rows are now logged too (action INSERT), so the whole move can be undone:
--    the last result shows the number to undo it with:  select undo_transaction(<that number>);

-- ---------------------------------------------------------------- change_log: added rows can be logged and undone
alter table public.change_log drop constraint if exists change_log_action_check;
alter table public.change_log add constraint change_log_action_check check (action in ('INSERT', 'UPDATE', 'DELETE'));

create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  pk text := tg_argv[0];
  o jsonb := to_jsonb(old);
  n jsonb;
  cols text[];
begin
  if current_setting('app.system_change', true) = 'on' then return coalesce(new, old); end if;
  if tg_op = 'INSERT' then
    n := to_jsonb(new);
    insert into public.change_log (changed_by, table_name, row_key, action, new_values)
    values (public.who(), tg_table_name, n ->> pk, 'INSERT', n);
    return new;
  elsif tg_op = 'UPDATE' then
    n := to_jsonb(new);
    select array_agg(k order by k) into cols from jsonb_object_keys(n) k
     where k not in ('updated_at') and (o -> k) is distinct from (n -> k);
    if cols is null then return new; end if;
    insert into public.change_log (changed_by, table_name, row_key, action, changed_columns, old_values, new_values)
    values (public.who(), tg_table_name, o ->> pk, 'UPDATE', cols,
            (select jsonb_object_agg(k, o -> k) from unnest(cols) k), (select jsonb_object_agg(k, n -> k) from unnest(cols) k));
    return new;
  else
    insert into public.change_log (changed_by, table_name, row_key, action, old_values)
    values (public.who(), tg_table_name, o ->> pk, 'DELETE', o);
    return old;
  end if;
end $function$;

-- marketing copy: rows added (in the Catalog Editor's Teasers column, by the Notion sync, or by this script) are logged too
drop trigger if exists marketing_copy_log on public.marketing_copy;
create trigger marketing_copy_log after insert or delete or update on public.marketing_copy
  for each row execute function public.log_change('id');

create or replace function public.undo_change(p_id bigint)
returns text language plpgsql security definer set search_path to 'public' as $function$
declare
  c public.change_log;
  pk text;
  sets text;
begin
  select * into c from public.change_log where id = p_id;
  if not found then raise exception 'No change % in change_log', p_id; end if;
  if c.undone_at is not null then raise exception 'Change % was already undone on %', p_id, c.undone_at; end if;
  select a.attname into pk from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = ('public.' || quote_ident(c.table_name))::regclass and i.indisprimary;
  if c.action = 'UPDATE' then
    select string_agg(format('%I = r.%I', k, k), ', ') into sets from unnest(c.changed_columns) k;
    execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I, $1) r where t.%I::text = $2',
                   c.table_name, sets, c.table_name, pk) using c.old_values, c.row_key;
  elsif c.action = 'INSERT' then  -- an added row: undoing it deletes the row
    execute format('delete from public.%I where %I::text = $1', c.table_name, pk) using c.row_key;
  else
    execute format('insert into public.%I overriding system value select * from jsonb_populate_record(null::public.%I, $1)',
                   c.table_name, c.table_name) using c.old_values;
  end if;
  update public.change_log set undone_at = now() where id = p_id;
  return format('Undid %s on %s %s', lower(c.action), c.table_name, c.row_key);
end $function$;

create or replace function public.undo_transaction(p_tx bigint)
returns text language plpgsql security definer set search_path to 'public' as $function$
declare r record; n int := 0;
begin
  -- deleted parents first (oldest first), then edits and added rows newest first
  for r in select id from public.change_log where transaction_id = p_tx and undone_at is null and action = 'DELETE' order by id loop
    perform public.undo_change(r.id); n := n + 1;
  end loop;
  for r in select id from public.change_log where transaction_id = p_tx and undone_at is null and action in ('UPDATE', 'INSERT') order by id desc loop
    perform public.undo_change(r.id); n := n + 1;
  end loop;
  return format('Undid %s changes', n);
end $function$;

create or replace function public.undo_recent(p_minutes integer, p_who text default null)
returns text language plpgsql security definer set search_path to 'public' as $function$
declare r record; n int := 0; w text := coalesce(p_who, public.who());
begin
  perform set_config('app.undoing', 'on', true);
  for r in select id from public.change_log where changed_by = w and undone_at is null and action = 'DELETE'
             and changed_at > now() - make_interval(mins => p_minutes) order by id loop
    perform public.undo_change(r.id); n := n + 1;
  end loop;
  for r in select id from public.change_log where changed_by = w and undone_at is null and action in ('UPDATE', 'INSERT')
             and changed_at > now() - make_interval(mins => p_minutes) order by id desc loop
    perform public.undo_change(r.id); n := n + 1;
  end loop;
  return format('Undid %s changes by %s', n, w);
end $function$;

create or replace view public.recent_changes with (security_invoker = true) as
 select id, changed_at, changed_by, table_name, row_key, action, changed_columns,
   case
     when action = 'UPDATE' then (select string_agg(k.k || ': ' || coalesce(left(change_log.old_values ->> k.k, 60), '(blank)') || ' → '
                                                    || coalesce(left(change_log.new_values ->> k.k, 60), '(blank)'), E'\n')
                                    from unnest(change_log.changed_columns) k(k))
     when action = 'INSERT' then 'added row'
     else 'deleted row'
   end as summary,
   transaction_id, undone_at
 from public.change_log
 order by id desc;

-- ---------------------------------------------------------------- the move, worked out first
drop table if exists teaser_move;
create temp table teaser_move as
with
src as (
  select 'E'::text src, e.file_name, 0::bigint row_id, 0 row_sort, e.excerpts txt
    from public.editions e where nullif(btrim(e.excerpts), '') is not null
  union all
  select 'T', m.file_name, m.id, coalesce(m.sort_order, 0), m.copy_text
    from public.marketing_copy m where m.copy_type = 'Teaser' and length(btrim(m.copy_text)) > 300
),
lines as (
  select s.src, s.file_name, s.row_id, s.row_sort, t.ord, rtrim(t.l, E'\r') l
    from src s, regexp_split_to_table(s.txt, E'\n') with ordinality t(l, ord)
),
marked as (   -- a heading line ("Teasers:", "Excerpts", "Teasers ch 1") goes; a label line ("Teaser #2:", "#3 (chapter 4)", "5") starts a piece
  select *,
    l ~* '^\s*(#{1,6}\s*)?\**\s*(teasers?|excerpts?)(\s*/\s*(teasers?|excerpts?))?(\s+(ch|chapter)\s*[0-9]+)?\s*:?\s*\**\s*$' as is_head,
    l ~* '^\s*(#{1,6}\s+)?\**\s*(teasers?|excerpts?)\s*#?\s*[0-9]+\M' or (length(l) <= 80 and l ~* '^\s*(#{1,6}\s+)?\**\s*#\s*[0-9]+\M')
      or l ~ '^\s*[0-9]{1,2}\s*$' as is_label
  from lines
),
grouped as (
  select *, sum(is_label::int) over (partition by src, file_name, row_id order by ord) grp from marked where not is_head
),
pieces as (
  select src, file_name, row_id, row_sort, grp,
    max(case when is_label then l end) label,
    btrim(coalesce(string_agg(case when not is_label then l end, E'\n' order by ord), ''), E' \t\r\n') raw_body
  from grouped group by 1, 2, 3, 4, 5
),
noted as (    -- what follows a label's number: a note ("(chapter 3)", "mid ch 7", "— The plan") or the passage's first line ("Four weeks.")
  select *, btrim(regexp_replace(regexp_replace(coalesce(label, ''),
           '^\s*(#{1,6}\s+)?\**\s*(teasers?\s*#?\s*[0-9]+|excerpts?\s*#?\s*[0-9]+|#\s*[0-9]+|[0-9]+\s*$)', '', 'i'), '\**\s*$', ''), E' \t:') note
  from pieces
),
noted2 as (
  select *, note = '' or note ~ '^[(—–-]' or note ~* '^(from\s+)?(ch\.?|chapter|prologue|epilogue|mid|near|end|begin|beginning)\M' as is_note from noted
),
p as (        -- body: the passage (a first line written on the label line moves under it); label_tail: the note kept after "Excerpt N"
  select *, lower(regexp_replace(body, '[^[:alnum:]]', '', 'g')) nb
  from (select *,
          case when is_note then raw_body else btrim(note || E'\n' || raw_body, E' \t\r\n') end body,
          case when not is_note or note = '' then '' when note ~ '^[(—–-]' then ' ' || note else ': ' || note end label_tail
        from noted2) x
  where body <> '' and body !~* '^(none|n/?a)$'
),
old_ex as (select file_name, lower(regexp_replace(excerpts, '[^[:alnum:]]', '', 'g')) ne from public.editions),
ep as (       -- pieces of editions.excerpts
  -- a short first line before the first label ("Excerpts for Dalla.", a title) stays at the top, unlabeled
  select p.*, case when grp = 0 and (length(body) < 40 or (body !~ E'\n' and length(body) < 60 and exists (select 1 from marked m where m.src = 'E' and m.file_name = p.file_name and m.is_label))) then 'pre'
                   when length(body) <= 300 then 'teaser' else 'excerpt' end cls
  from p where src = 'E'
),
tp0 as (      -- pieces of the long Teaser rows
  select p.*, case when length(body) < 40 then 'junk' when length(body) <= 300 then 'teaser'
                   -- already in the excerpts: the whole passage, or the same passage with small edits (same first and last lines)
                   when position(p.nb in coalesce(o.ne, '')) > 0
                     or (length(p.nb) > 300 and position(left(p.nb, 100) in coalesce(o.ne, '')) > 0 and position(right(p.nb, 100) in coalesce(o.ne, '')) > 0) then 'inside'
                   else 'long' end cls
  from p left join old_ex o using (file_name) where src = 'T'
),
claim as (    -- an excerpt that a longer teaser passage holds in full is replaced by that passage
  select distinct on (e.file_name, e.grp) e.file_name, e.grp egrp, t.row_id, t.grp tgrp
  from ep e join tp0 t on t.file_name = e.file_name and t.cls = 'long' and position(e.nb in t.nb) > 0
  where e.cls = 'excerpt' order by e.file_name, e.grp, t.row_sort, t.row_id, t.grp
),
slot as (select distinct on (file_name, row_id, tgrp) * from claim order by file_name, row_id, tgrp, egrp),
tp as (
  select t.*, case when t.cls <> 'long' then t.cls when s.egrp is not null then 'replace' else 'append' end cls2, s.egrp slot
  from tp0 t left join slot s on s.file_name = t.file_name and s.row_id = t.row_id and s.tgrp = t.grp
),
final_ex as ( -- the excerpts after the move, in order
  select e.file_name, 0 k, e.grp pos, 0::bigint rid, 0 tg, e.body, e.label is not null labeled, e.label_tail
    from ep e where e.cls = 'excerpt' and not exists (select 1 from claim c where c.file_name = e.file_name and c.egrp = e.grp)
  union all
  select t.file_name, 0, t.slot, t.row_id, t.grp, t.body, e.label is not null, case when t.label_tail <> '' then t.label_tail else e.label_tail end
    from tp t join ep e on e.file_name = t.file_name and e.grp = t.slot where t.cls2 = 'replace'
  union all
  select t.file_name, 1, t.row_sort, t.row_id, t.grp, t.body, true, t.label_tail from tp t where t.cls2 = 'append'
),
numbered as (
  select f.*, row_number() over w n, count(*) over (partition by file_name) total
  from final_ex f window w as (partition by file_name order by k, pos, rid, tg)
),
touched as (  -- editions whose excerpts change: a label or heading line, a piece that moves, or a teaser passage that comes in
  select distinct file_name from marked where src = 'E' and (is_label or is_head)
  union select file_name from ep where cls <> 'excerpt'
  union select file_name from tp
),
new_ex as (
  select t.file_name,
    nullif(concat_ws(E'\n\n',
      (select string_agg(body, E'\n\n' order by grp) from ep where ep.file_name = t.file_name and cls = 'pre'),
      (select string_agg(case when labeled or total > 1 then 'Excerpt ' || n || label_tail || E'\n' || body else body end, E'\n\n' order by n)
         from numbered x where x.file_name = t.file_name)), '') excerpts
  from touched t
),
kept_teasers as (
  select file_name, id, sort_order, lower(regexp_replace(copy_text, '[^[:alnum:]]', '', 'g')) nt
  from public.marketing_copy where copy_type = 'Teaser' and length(btrim(copy_text)) <= 300
),
cand as (
  select file_name, 0 k, grp a, 0::bigint b, 0 c, body from ep where cls = 'teaser'
  union all select file_name, 1, row_sort, row_id, grp, body from tp where cls2 = 'teaser'
),
cand2 as (
  select distinct on (file_name, nt) *
  from (select c.*, lower(regexp_replace(c.body, '[^[:alnum:]]', '', 'g')) nt from cand c) x
  where not exists (select 1 from kept_teasers k where k.file_name = x.file_name and k.nt = x.nt)
  order by file_name, nt, k, a, b, c
),
new_teasers as (
  select c.file_name, c.body copy_text,
    coalesce((select max(sort_order) from kept_teasers k where k.file_name = c.file_name), 0) + row_number() over (partition by c.file_name order by k, a, b, c) sort_order
  from cand2 c
)
select 'excerpts'::text kind, file_name, excerpts txt, null::bigint num from new_ex
union all select 'teaser', file_name, copy_text, sort_order from new_teasers
union all select 'delete', file_name, null, row_id from src where src = 'T';

-- ---------------------------------------------------------------- the move
update public.editions e set excerpts = m.txt
  from teaser_move m where m.kind = 'excerpts' and m.file_name = e.file_name and e.excerpts is distinct from m.txt;

delete from public.marketing_copy
 where copy_type = 'Teaser' and id in (select num from teaser_move where kind = 'delete');

insert into public.marketing_copy (file_name, copy_type, sort_order, copy_text)
select file_name, 'Teaser', num, txt from teaser_move where kind = 'teaser' order by file_name, num;

drop table teaser_move;

-- ---------------------------------------------------------------- what changed, and how to undo it
select format('%s books'' Excerpts changed, %s long Teaser rows deleted, %s Teaser rows added. To undo all of it, run:  select undo_transaction(%s);',
         count(*) filter (where table_name = 'editions' and action = 'UPDATE'),
         count(*) filter (where table_name = 'marketing_copy' and action = 'DELETE'),
         count(*) filter (where table_name = 'marketing_copy' and action = 'INSERT'),
         txid_current()) as result
  from public.change_log where transaction_id = txid_current();
