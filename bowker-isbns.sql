-- Bowker ISBNs: run once in the Supabase SQL Editor.
-- A daily GitHub job (.github/workflows/bowker-isbns.yml in the catalog-editor repo) signs in to
-- myidentifiers.com, reads the list of ISBNs and sends it here through bowker_isbns_save().
--  1. bowker_isbns: every ISBN Bowker lists, with its title, format and status. Only signed-in users
--     (the Catalog Editor) can read it; the public Payhip footer key cannot.
--  2. bowker_sync_secret: the hash of the code the GitHub job sends. Nobody can read it.
--  3. bowker_isbns_save(code, rows): saves the list and puts each new ISBN into the empty ISBN cell of
--     the one book whose title and format match. Anything else is left for you in the view below.
--  4. bowker_isbns_to_check: Bowker ISBNs with a title that are not in the catalog yet.
--  5. Makes the code and shows it ONCE: copy it into the GitHub secret BOWKER_SYNC_TOKEN.
--     Running this script again makes a new code (the old one stops working).

-- ============ 1. the list ============
create table if not exists public.bowker_isbns (
  isbn        text primary key check (isbn ~ '^97[89][0-9]{10}$'),
  title       text,
  format      text,
  status      text,
  cells       jsonb,
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  filled_into text,   -- where the ISBN was put, or 'already in the catalog'
  note        text    -- why it was not filled in
);
comment on table public.bowker_isbns is 'ISBNs read from myidentifiers.com by the daily GitHub job. Signed-in read only; written only by bowker_isbns_save().';
alter table public.bowker_isbns enable row level security;
revoke all on public.bowker_isbns from anon, authenticated;
grant select on public.bowker_isbns to authenticated;
drop policy if exists bowker_isbns_signed_in_read on public.bowker_isbns;
create policy bowker_isbns_signed_in_read on public.bowker_isbns for select to authenticated using (true);

-- ============ 2. the job's code ============
create table if not exists public.bowker_sync_secret (
  id integer primary key default 1 check (id = 1),
  token_hash text not null
);
comment on table public.bowker_sync_secret is 'sha256 of the code the GitHub job sends. No policies on purpose: only bowker_isbns_save() reads it.';
alter table public.bowker_sync_secret enable row level security;
revoke all on public.bowker_sync_secret from anon, authenticated;

-- ============ 3. save + fill ============
create or replace function public.bowker_title_key(t text)
returns text language sql immutable set search_path = public, pg_temp as $f$
  select nullif(regexp_replace(lower(coalesce(t,'')), '[^[:alnum:]]+', '', 'g'), '')
$f$;

create or replace function public.bowker_isbns_save(p_token text, p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare
  r        record;
  v_new    int := 0;
  v_seen   int := 0;
  v_was    boolean;
  v_fmt    text;
  v_ids    bigint[];
  v_filled jsonb := '[]'::jsonb;
  v_file   text;
begin
  if not exists (select 1 from bowker_sync_secret
                  where id = 1 and token_hash = encode(sha256(convert_to(coalesce(p_token,''), 'UTF8')), 'hex')) then
    raise exception 'Wrong BOWKER_SYNC_TOKEN';
  end if;

  for r in select * from jsonb_to_recordset(coalesce(p_rows, '[]'::jsonb))
                 as x(isbn text, title text, format text, status text, cells jsonb) loop
    continue when coalesce(r.isbn,'') !~ '^97[89][0-9]{10}$';
    v_seen := v_seen + 1;
    v_was := exists (select 1 from bowker_isbns where isbn = r.isbn);
    insert into bowker_isbns (isbn, title, format, status, cells)
    values (r.isbn, nullif(trim(r.title),''), nullif(trim(r.format),''), nullif(trim(r.status),''), r.cells)
    on conflict (isbn) do update
      set title  = coalesce(excluded.title,  bowker_isbns.title),
          format = coalesce(excluded.format, bowker_isbns.format),
          status = coalesce(excluded.status, bowker_isbns.status),
          cells  = excluded.cells,
          last_seen = now();
    if not v_was then v_new := v_new + 1; end if;
  end loop;

  -- put each not-yet-used ISBN into the one empty ISBN cell whose title and format match
  for r in select * from bowker_isbns where filled_into is null and title is not null loop
    if exists (select 1 from formats where r.isbn in (isbn, amazon_isbn, bn_isbn))
       or exists (select 1 from story_bibles where isbn = r.isbn) then
      update bowker_isbns set filled_into = 'already in the catalog', note = null where isbn = r.isbn;
      continue;
    end if;
    if r.title ~* 'story bible' then
      update bowker_isbns set note = 'story bible: fill it in by hand' where isbn = r.isbn;
      continue;
    end if;
    v_fmt := case
      when r.format ~* 'audio'                                   then 'Audiobook'
      when r.format ~* 'hard|cloth|case|library binding'          then 'Hardcover'
      when r.format ~* 'paper|trade|mass market|soft'             then 'Paperback'
      when r.format ~* 'e-?book|epub|digital|electronic|kindle|mobi|pdf' then 'eBook'
    end;
    if v_fmt is null then
      update bowker_isbns set note = 'format not recognised' where isbn = r.isbn;
      continue;
    end if;
    select array_agg(f.id) into v_ids
      from formats f join editions e on e.file_name = f.file_name
     where f.format = v_fmt and nullif(trim(coalesce(f.isbn,'')),'') is null
       and not coalesce(f.not_offered, false)
       and bowker_title_key(e.title) = bowker_title_key(r.title);
    if coalesce(array_length(v_ids,1),0) = 1 then
      update formats set isbn = r.isbn where id = v_ids[1] returning file_name into v_file;
      update bowker_isbns set filled_into = format('%s %s', v_file, v_fmt), note = null where isbn = r.isbn;
      v_filled := v_filled || jsonb_build_object('isbn', r.isbn, 'book', v_file, 'format', v_fmt);
    else
      update bowker_isbns
         set note = case when coalesce(array_length(v_ids,1),0) = 0
                         then format('no %s with this title and an empty ISBN', v_fmt)
                         else format('%s %s rows with this title have an empty ISBN', array_length(v_ids,1), v_fmt) end
       where isbn = r.isbn;
    end if;
  end loop;

  return jsonb_build_object(
    'seen', v_seen, 'new', v_new, 'filled', v_filled,
    'to_check', (select count(*) from bowker_isbns where filled_into is null and title is not null));
end
$fn$;
revoke all on function public.bowker_isbns_save(text, jsonb) from public;
grant execute on function public.bowker_isbns_save(text, jsonb) to anon, authenticated;

-- ============ 4. what is left for you ============
create or replace view public.bowker_isbns_to_check with (security_invoker = true) as
  select isbn, title, format, status, note, first_seen
    from public.bowker_isbns
   where filled_into is null and title is not null
   order by first_seen desc, title;
revoke all on public.bowker_isbns_to_check from anon;
grant select on public.bowker_isbns_to_check to authenticated;

-- ============ 5. the code (copy it into GitHub) ============
with t as (select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') as tok),
saved as (
  insert into public.bowker_sync_secret (id, token_hash)
  select 1, encode(sha256(convert_to(tok, 'UTF8')), 'hex') from t
  on conflict (id) do update set token_hash = excluded.token_hash
  returning 1
)
select tok as "Copy this into the GitHub secret BOWKER_SYNC_TOKEN" from t, saved;
