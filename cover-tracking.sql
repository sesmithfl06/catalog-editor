-- Cover tracking: run once in the Supabase SQL Editor (safe to run again).
--  1. covers: one row for each cover of a book that is done at one stage. Ticked in the Catalog Editor's Release workflow
--     (the cover lists in the ChatGPT covers step, the print covers step, the Photoshop cover line step and the bundle cover step).
--     Shared by every device and person; every add and removal is in change_log, so undo_change / undo_transaction can reverse it.
--       stage 'created'   = ChatGPT made it (first-stage covers; Photoshop for the bundle cover)
--       stage 'print_fit' = ChatGPT fitted the draft print cover to the KDP and B&N templates
--       stage 'line'      = Photoshop: the NYT line (translations: the cover text lines) added
--  2. cover_status_for(p_files) / cover_status: every cover each book in progress needs (not released or released in the last
--     60 days), at each stage, done or not. The list follows the Release workflow: English books get the eBook cover, the no-text
--     art, the audiobook cover (Dragon Box books, or when an audiobook is offered), print covers (when a paperback or hardcover is
--     offered) and the story bible and bundle covers (Dragon Box books, or when the book has a story bible); translations get the
--     cover text lines on the eBook and print covers.
--     Covers still to make:  select * from cover_status where not done order by publication_date, file_name, cover_order;

-- ============ 1. covers ============
create table if not exists public.covers (
  id         bigint generated always as identity primary key,
  file_name  text not null references public.editions(file_name) on update cascade on delete cascade,
  cover      text not null check (cover in ('eBook', 'Audiobook', 'eBook art (no text)', 'Square art (no text)', 'Paperback',
                                            'Paperback (no text)', 'Hardcover', 'Print', 'Story bible', 'Bundle')),
  stage      text not null check (stage in ('created', 'print_fit', 'line')),
  done_on    date not null default current_date,
  done_by    text default public.who(),
  source     text not null default 'Catalog Editor',
  note       text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (file_name, cover, stage)
);
comment on table public.covers is 'Covers done, one row per book, cover and stage (created, print_fit, line): ticked in the Catalog Editor Release workflow. See cover-tracking.sql and the cover_status view.';
alter table public.covers enable row level security;
revoke all on public.covers from anon;
grant select, insert, update, delete on public.covers to authenticated;
drop policy if exists team_read on public.covers;
create policy team_read on public.covers for select using (public.team_role() is not null);
drop policy if exists team_write on public.covers;
create policy team_write on public.covers for all
  using (public.team_role() = any (array['owner', 'editor']))
  with check (public.team_role() = any (array['owner', 'editor']));
drop trigger if exists covers_log on public.covers;
create trigger covers_log after insert or update or delete on public.covers
  for each row execute function public.log_change('id');
drop trigger if exists covers_touch on public.covers;
create trigger covers_touch before update on public.covers
  for each row execute function public.touch_updated_at();
drop trigger if exists covers_no_truncate on public.covers;
create trigger covers_no_truncate before truncate on public.covers
  for each statement execute function public.guard_truncate();
-- A tick on one device shows in a Release workflow open on another.
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'covers') then
    alter publication supabase_realtime add table public.covers;
  end if;
end $$;

-- ============ 2. cover_status ============
drop view if exists public.cover_status;
create or replace function public.cover_status_for(p_files text[] default null)
returns table(file_name text, title text, language text, sheet_order integer, publication_date date,
              subscription_publication date, dragon_box boolean, cover_order integer, cover text, stage text,
              step text, done boolean, done_on date, done_by text)
language sql stable security invoker as $fn$
with b as (
  select e.file_name, e.title, e.language, e.sheet_order, e.publication_date as pub, e.subscription_publication as sub,
         e.language = 'English' as english, e.language = 'English' and e.subscription_publication is not null as db
    from public.edition_info e
   where e.not_released_reason is null
     and not coalesce(e.anthology_only, false)
     and e.file_name !~ '(BX|\+|TWOSES|LOK-05-Madas)'
     and (p_files is null or e.file_name = any(p_files))
     and (e.publication_date is null or e.publication_date >= current_date - 60
          or e.subscription_publication >= current_date - 60
          or exists (select 1 from public.covers c where c.file_name = e.file_name and c.done_on >= current_date - 60))
),
f as (
  select x.file_name,
         bool_or(x.format = 'Audiobook' and not coalesce(x.not_offered, false)) as aud,
         bool_or(x.format = 'Paperback' and not coalesce(x.not_offered, false)) as pb,
         bool_or(x.format = 'Hardcover' and not coalesce(x.not_offered, false)) as hc
    from public.formats x where x.file_name in (select file_name from b) group by x.file_name
),
k as (
  select b.*, coalesce(f.aud, false) as aud, coalesce(f.pb, false) as pb, coalesce(f.hc, false) as hc,
         b.db or exists (select 1 from public.story_bibles s where s.file_name = b.file_name) as bible
    from b left join f on f.file_name = b.file_name
),
needs as (
  select k.*, n.cover_order, n.cover, n.stage
    from k cross join lateral (values
      ( 1, 'eBook',                'created',   k.english),
      ( 2, 'Audiobook',            'created',   k.english and (k.db or k.aud)),
      ( 3, 'eBook art (no text)',  'created',   k.english),
      ( 4, 'Square art (no text)', 'created',   k.english),
      ( 5, 'Paperback',            'created',   k.english and k.pb),
      ( 6, 'Paperback (no text)',  'created',   k.english and k.pb),
      ( 7, 'Hardcover',            'created',   k.english and k.hc),
      ( 8, 'Story bible',          'created',   k.english and k.bible),
      ( 9, 'Paperback',            'print_fit', k.english and k.pb),
      (10, 'Paperback (no text)',  'print_fit', k.english and k.pb),
      (11, 'Hardcover',            'print_fit', k.english and k.hc),
      (12, 'eBook',                'line',      true),
      (13, 'Audiobook',            'line',      k.english and (k.db or k.aud)),
      (14, 'Paperback',            'line',      k.english and k.pb),
      (15, 'Hardcover',            'line',      k.english and k.hc),
      (16, 'Print',                'line',      not k.english and (k.pb or k.hc)),
      (17, 'Story bible',          'line',      k.english and k.bible),
      (18, 'Bundle',               'created',   k.english and k.bible)
    ) n(cover_order, cover, stage, applies)
   where n.applies
)
select n.file_name, n.title, n.language, n.sheet_order, n.pub, n.sub, n.db, n.cover_order, n.cover, n.stage,
       case when n.cover = 'Bundle' then 'Photoshop: bundle cover made'
            when n.stage = 'created' then 'ChatGPT: first-stage cover made'
            when n.stage = 'print_fit' then 'ChatGPT: fitted to the KDP and B&N templates'
            when n.english then 'Photoshop: NYT line added'
            else 'Photoshop: cover text lines added' end,
       c.id is not null, c.done_on, c.done_by
  from needs n
  left join public.covers c on c.file_name = n.file_name and c.cover = n.cover and c.stage = n.stage
 order by n.sheet_order nulls last, n.file_name, n.cover_order;
$fn$;
grant execute on function public.cover_status_for(text[]) to authenticated;
create view public.cover_status with (security_invoker = true) as select * from public.cover_status_for(null);
grant select on public.cover_status to authenticated;
revoke all on public.cover_status from anon;
comment on view public.cover_status is 'Every cover each book in progress needs, at each stage, done or not (from the covers table). See cover-tracking.sql.';
