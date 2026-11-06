-- Release workflow: run once in the Supabase SQL Editor (safe to run again).
--  1. release_steps: release steps that have no other data to show them done. Ticked in the Catalog Editor's
--     Release panel (Vellum formatting, cover, subscription post, Payhip product Live, uploaded) and written by
--     the Distribution app when it finishes a distributor ('dist:<distributor>' rows). Every add, change and
--     removal is in change_log, so undo_change / undo_transaction can reverse it.
--  2. release_checklist: every book in progress (not released or released in the last 60 days) with each step
--     of its workflow, done or not, how it was done, its due date and what is still missing. Most steps tick
--     themselves from the catalog (new_book_passes, store_link_blanks, ISBNs, payhip_products, story_bibles).
--       English: Before Subsc Pub -> Payhip -> Wide release. Other languages: Before release -> Release and after
--       (Payhip is part of the release). Get ISBNs is due by Subsc Pub (English) or release (other languages);
--       store links are due 2 days after the date of that format.
--  3. release_fill_blanks(file_name, items): what the Distribution app calls. It only fills blank values and
--     adds 'done' rows; it never overwrites or deletes anything. Owners and editors only.

-- ============ 1. release_steps ============
create table if not exists public.release_steps (
  id         bigint generated always as identity primary key,
  file_name  text not null references public.editions(file_name) on update cascade on delete cascade,
  step       text not null,
  done_on    date not null default current_date,
  done_by    text default public.who(),
  source     text not null default 'Catalog Editor',
  note       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (file_name, step)
);
comment on table public.release_steps is 'Release steps done that no other data shows: ticked in the Catalog Editor Release panel, or written by the Distribution app (dist:<distributor>). See release-workflow.sql.';
alter table public.release_steps enable row level security;
revoke all on public.release_steps from anon;
grant select, insert, update, delete on public.release_steps to authenticated;
drop policy if exists team_read on public.release_steps;
create policy team_read on public.release_steps for select using (public.team_role() is not null);
drop policy if exists team_write on public.release_steps;
create policy team_write on public.release_steps for all
  using (public.team_role() = any (array['owner', 'editor']))
  with check (public.team_role() = any (array['owner', 'editor']));
drop trigger if exists release_steps_log on public.release_steps;
create trigger release_steps_log after insert or update or delete on public.release_steps
  for each row execute function public.log_change('id');
drop trigger if exists release_steps_touch on public.release_steps;
create trigger release_steps_touch before update on public.release_steps
  for each row execute function public.touch_updated_at();
drop trigger if exists release_steps_no_truncate on public.release_steps;
create trigger release_steps_no_truncate before truncate on public.release_steps
  for each statement execute function public.guard_truncate();

-- ============ 2. release_checklist ============
-- release_checklist_for(p_files): the checklist for only the named books (null = every book in progress).
-- The filter sits at the very start, so asking for one book only works out that one book. Filtering the
-- view afterwards still worked out every book first and timed out.
drop view if exists public.release_checklist;
create or replace function public.release_checklist_for(p_files text[] default null)
returns table(file_name text, title text, language text, sheet_order integer, publication_date date,
              subscription_publication date, stage integer, stage_name text, step_order integer, step_key text,
              step text, done boolean, done_how text, done_on date, done_by text, due date, overdue boolean,
              detail text, can_tick boolean)
language sql stable security invoker set statement_timeout = '60s' as $fn$
with b as (
  select e.file_name, e.title, e.language, e.sheet_order, e.series, e.number_in_series,
         e.publication_date as pub, e.subscription_publication as sub,
         coalesce(e.kindle_unlimited, false) as ku, e.cover_image_link, coalesce(e.vellum_link_created, false) as vellum_link,
         e.language = 'English' as english
    from public.edition_info e
   where e.not_released_reason is null
     and not coalesce(e.anthology_only, false)
     and e.file_name !~ '(BX|\+|TWOSES)'
     and (p_files is null or e.file_name = any(p_files))
     and (e.publication_date is null or e.publication_date >= current_date - 60
          or e.subscription_publication >= current_date - 60
          or exists (select 1 from public.release_steps r where r.file_name = e.file_name and r.done_on >= current_date - 60))
),
passes as (
  select file_name, pass, still_blank from public.new_book_passes where file_name in (select file_name from b)
),
blanks as (
  select file_name, case when format in ('eBook','Paperback') then 'main' when format in ('Story Bible','Bundle') then 'bible' else lower(format) end as grp,
         string_agg(store || ' ' || format, ', ' order by format, store) as missing
    from public.store_link_blanks where file_name in (select file_name from b)
   group by 1, 2
),
fmt as (
  select file_name,
         bool_or(format = 'Paperback' and not coalesce(not_offered, false)) or bool_or(format = 'Hardcover' and not coalesce(not_offered, false)) as print,
         bool_or(format = 'Hardcover' and not coalesce(not_offered, false) and coalesce(lower(btrim(isbn)), '') <> 'n/a') as hc,
         max(publication_date) filter (where format = 'Hardcover') as hc_pub,
         bool_or(format = 'Audiobook' and not coalesce(not_offered, false)) as audio,
         max(publication_date) filter (where format = 'Audiobook') as audio_pub
    from public.formats where file_name in (select file_name from b) group by 1
),
payhip as (
  select l.file_name, bool_or(p.status = 'Live') as live, string_agg(distinct p.status, ', ') as statuses
    from public.store_links l
    left join public.payhip_products p on p.code = substring(l.link_or_id from '/b/([A-Za-z0-9]+)')
   where l.store = 'Payhip' and l.format = 'eBook' and l.file_name in (select file_name from b)
     and not public.needs_value(l.link_or_id)
   group by 1
),
dist as (
  select file_name, max(done_on) as done_on,
         bool_or(step !~* '^dist:bowker') as uploaded,   -- Bowker registers ISBNs; it is not a store
         string_agg(substr(step, 6) || ' ' || to_char(done_on, 'Mon DD'), ', ' order by done_on, step) as which
    from public.release_steps where step like 'dist:%' group by 1
),
steps as (
  -- stage, order, key, label, applies, done by the data, due, detail
  select b.file_name, s.*
    from b
    left join fmt f using (file_name)
    left join payhip ph using (file_name)
    left join dist d using (file_name)
    left join public.story_bibles sb using (file_name)
    cross join lateral (values
      (1, 10, 'details', 'Book details filled (script check and your inputs)', true,
         not exists (select 1 from passes p where p.file_name = b.file_name and p.pass in (0, 1)), null::date,
         (select string_agg(p.still_blank, '; ' order by p.pass) from passes p where p.file_name = b.file_name and p.pass in (0, 1))),
      (1, 20, 'isbns', 'Get ISBNs (Bowker)', true,
         not exists (select 1 from passes p where p.file_name = b.file_name and p.pass = 2),
         case when b.english then coalesce(b.sub, b.pub) else b.pub end,
         (select p.still_blank from passes p where p.file_name = b.file_name and p.pass = 2)),
      (1, 30, 'vellum', case when b.english then 'Formatted in Vellum' else 'Formatted in Vellum from the ' || b.language || ' template' end, true,
         false, case when b.english then coalesce(b.sub, b.pub) else b.pub end, null),
      (1, 40, 'pages', 'Page count and size from the Vellum print file', coalesce(f.print, false),
         not exists (select 1 from passes p where p.file_name = b.file_name and p.pass = 3), null,
         (select p.still_blank from passes p where p.file_name = b.file_name and p.pass = 3)),
      (1, 50, 'cover', 'Cover done', true,
         not public.needs_value(b.cover_image_link), case when b.english then coalesce(b.sub, b.pub) else b.pub end, null),
      (1, 60, 'subscription_post', 'Added to the subscription post', b.english,
         false, b.sub, case when b.sub is null then 'No Subsc Pub date yet' end),
      (case when b.english then 2 else 3 end, 25, 'payhip_live', 'Payhip product Live', not b.ku,
         coalesce(ph.live, false), b.pub,
         case when ph.file_name is null then 'No Payhip eBook link yet' when not ph.live then 'Payhip says ' || coalesce(ph.statuses, 'nothing') end),
      (case when b.english then 2 else 3 end, 26, 'story_bible', 'Story bible approved', sb.file_name is not null,
         sb.status = 'Approved', sb.publication_date, case when sb.status is not null and sb.status <> 'Approved' then 'Status ' || sb.status end),
      (3, 10, 'distribution', 'Uploaded to the stores (Distribution app)', true,
         coalesce(d.uploaded, false)
           or (b.pub is not null and not exists (select 1 from blanks x where x.file_name = b.file_name and x.grp = 'main')),
         b.pub, d.which),
      (3, 20, 'vellum_link', 'Vellum link created', true,
         b.vellum_link, null, null),
      (3, 30, 'links_main', 'Get store links (eBook and paperback)', b.pub is not null,
         not exists (select 1 from blanks x where x.file_name = b.file_name and x.grp = 'main'), b.pub + 2,
         (select x.missing from blanks x where x.file_name = b.file_name and x.grp = 'main')),
      (3, 40, 'links_hardcover', 'Get store links (hardcover)', coalesce(f.hc, false) and coalesce(f.hc_pub, b.pub) is not null,
         not exists (select 1 from blanks x where x.file_name = b.file_name and x.grp = 'hardcover'), coalesce(f.hc_pub, b.pub) + 2,
         (select x.missing from blanks x where x.file_name = b.file_name and x.grp = 'hardcover')),
      (3, 50, 'links_audiobook', 'Get store links (audiobook)', coalesce(f.audio, false) and f.audio_pub is not null,
         not exists (select 1 from blanks x where x.file_name = b.file_name and x.grp = 'audiobook'), f.audio_pub + 2,
         (select x.missing from blanks x where x.file_name = b.file_name and x.grp = 'audiobook')),
      (3, 60, 'links_bible', 'Get store links (story bible and bundle)', sb.file_name is not null,
         not exists (select 1 from blanks x where x.file_name = b.file_name and x.grp = 'bible'), coalesce(sb.publication_date, b.pub) + 2,
         (select x.missing from blanks x where x.file_name = b.file_name and x.grp = 'bible'))
    ) s(stage, step_order, step_key, step, applies, done_by_data, due, detail)
   where s.applies
),
judged as (
  -- A step with nothing in the data to show it (Vellum, cover, subscription post) counts as done
  -- once its date has passed: a book already out was formatted and posted.
  select s.*,
         case when s.done_by_data and s.step_key = 'distribution' and s.detail is not null then 'Distribution app'
              when s.done_by_data then 'data'
              when s.step_key in ('vellum', 'cover', 'subscription_post') and s.due < current_date then 'date passed' end as auto_how
    from steps s
)
select b.file_name, b.title, b.language, b.sheet_order, b.pub as publication_date, b.sub as subscription_publication,
       s.stage,
       case s.stage when 1 then case when b.english then 'Before Subsc Pub' else 'Before release' end
                    when 2 then 'Payhip' else case when b.english then 'Wide release' else 'Release and after' end end as stage_name,
       s.step_order, s.step_key, s.step,
       s.auto_how is not null or r.file_name is not null as done,
       coalesce(case when r.file_name is not null then coalesce(r.source, 'ticked') end, s.auto_how) as done_how,
       r.done_on, r.done_by,
       s.due,
       s.auto_how is null and r.file_name is null and s.due is not null and s.due < current_date as overdue,
       s.detail,
       s.step_key in ('vellum', 'cover', 'subscription_post', 'payhip_live', 'distribution') as can_tick
  from judged s
  join b using (file_name)
  left join public.release_steps r on r.file_name = s.file_name and r.step = s.step_key
$fn$;
revoke all on function public.release_checklist_for(text[]) from public, anon;
grant execute on function public.release_checklist_for(text[]) to authenticated;

create view public.release_checklist with (security_invoker = true) as
  select * from public.release_checklist_for(null);

revoke all on public.release_checklist from anon;
grant select on public.release_checklist to authenticated;

-- ============ 3. release_fill_blanks ============
-- items: a JSON array of
--   {"kind":"isbn", "format":"Audiobook", "value":"978…"}                          fills formats.isbn when blank
--   {"kind":"link", "store":"Books2Read", "format":"eBook", "link_type":"Universal Link", "value":"https://…"}
--                                                                                   fills store_links when blank
--   {"kind":"done", "step":"dist:Amazon", "on":"2026-11-06"}                        adds a release_steps row
-- Returns one line per item: {item, result} where result is filled / added / already done /
-- already has <value> / same value / skipped: <why>.
create or replace function public.release_fill_blanks(p_file_name text, p_items jsonb, p_source text default 'Distribution app')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare
  it      jsonb;
  v_kind  text;
  v_val   text;
  v_old   text;
  v_id    bigint;
  v_row   jsonb;
  v_on    date;
  v_out   jsonb := '[]'::jsonb;
  v_res   text;
begin
  if coalesce(public.team_role(), '') not in ('owner', 'editor') then
    raise exception 'Only owners and editors can save to the catalog (sign in with your authenticator code).';
  end if;
  if not exists (select 1 from editions where file_name = p_file_name) then
    raise exception 'No book with file name %', p_file_name;
  end if;

  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_kind := lower(coalesce(it ->> 'kind', ''));
    v_val  := nullif(btrim(coalesce(it ->> 'value', '')), '');
    v_res  := null;
    v_id   := null;
    v_old  := null;

    begin   -- one item that fails (a store name not on the list, a bad date) does not stop the others
    if v_kind = 'isbn' then
      v_val := regexp_replace(coalesce(v_val, ''), '[^0-9Xx]', '', 'g');
      if v_val !~ '^97[89][0-9]{10}$' then
        v_res := 'skipped: not a 13-digit ISBN';
      else
        select id, isbn into v_id, v_old from formats where file_name = p_file_name and format = it ->> 'format';
        if v_id is null then
          v_res := format('skipped: the book has no %s format', it ->> 'format');
        elsif not needs_value(v_old) then
          v_res := case when btrim(v_old) = v_val then 'same value' else 'already has ' || v_old end;
        elsif exists (select 1 from formats where v_val in (isbn, amazon_isbn, bn_isbn))
              or exists (select 1 from story_bibles where isbn = v_val) then
          v_res := 'skipped: this ISBN is already on another book';
        else
          update formats set isbn = v_val where id = v_id;   -- formats_log records it
          v_res := 'filled';
        end if;
      end if;

    elsif v_kind = 'link' then
      if v_val is null then
        v_res := 'skipped: empty';
      else
        select id, link_or_id into v_id, v_old from store_links
         where file_name = p_file_name and store = it ->> 'store' and format = it ->> 'format' and link_type = it ->> 'link_type';
        if v_id is not null and not needs_value(v_old) then
          v_res := case when btrim(v_old) = v_val then 'same value' else 'already has ' || v_old end;
        elsif v_id is not null then
          update store_links set link_or_id = v_val where id = v_id;   -- store_links_log records it
          v_res := 'filled';
        else
          insert into store_links (file_name, store, format, link_type, link_or_id)
          values (p_file_name, it ->> 'store', it ->> 'format', it ->> 'link_type', v_val)
          returning to_jsonb(store_links.*) into v_row;
          -- store_links logs only changes and removals, so the new row is logged here (undo deletes it)
          insert into change_log (changed_by, table_name, row_key, action, new_values)
          values (public.who(), 'store_links', v_row ->> 'id', 'INSERT', v_row);
          v_res := 'filled';
        end if;
      end if;

    elsif v_kind = 'done' then
      v_on := coalesce(nullif(it ->> 'on', '')::date, current_date);
      if coalesce(it ->> 'step', '') = '' then
        v_res := 'skipped: no step';
      elsif exists (select 1 from release_steps where file_name = p_file_name and step = it ->> 'step') then
        v_res := 'already done';
      else
        insert into release_steps (file_name, step, done_on, source, note)
        values (p_file_name, it ->> 'step', v_on, coalesce(nullif(p_source, ''), 'Distribution app'), nullif(it ->> 'note', ''));
        v_res := 'added';
      end if;

    else
      v_res := 'skipped: unknown kind';
    end if;
    exception when others then
      v_res := 'skipped: ' || sqlerrm;
    end;

    v_out := v_out || jsonb_build_object('item', it, 'result', v_res);
  end loop;
  return v_out;
end
$fn$;
revoke all on function public.release_fill_blanks(text, jsonb, text) from public, anon;
grant execute on function public.release_fill_blanks(text, jsonb, text) to authenticated;

-- check: the books in progress and how far each one is
select title, language, count(*) filter (where done) || ' of ' || count(*) as done,
       count(*) filter (where overdue) as overdue
  from public.release_checklist group by file_name, title, language, sheet_order order by sheet_order;
