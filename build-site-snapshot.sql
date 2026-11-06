-- Payhip footer reads its book data from Supabase.  Run ONCE in Supabase -> SQL Editor (whole file).
-- Plan: supabase-snapshot-plan.md in the Make-Payhip-Footer repo.
--
--  1. Fixes "You might also like" being slow (also_like took ~37 s; now ~0.6 s), same suggestions, same order.
--     One change on purpose: a book is recommended on other books' pages from its release day
--     (it used to use the subscription day before the release day),
--     so a book put up early only for its link is not recommended before it is out.
--  2. Two views the public key could read (print_id_check, store_link_blanks) now follow the reader's own rights.
--     "Find store links for shown books" also lists blank hardcover, audiobook, story bible and bundle links.
--  3. site_snapshot: ONE row of JSON with only what the website shows. Anyone can read it; nobody can change it.
--     Every other table stays signed-in only.
--  4. Triggers on the tables the snapshot uses only set a "needs rebuild" mark (saving stays instant).
--  5. pg_cron: every minute rebuilds the snapshot if it is marked, and every day at 00:00 UTC
--     (so release days, "coming soon" and recommendations of a book that came out today change on their own).
--  6. Builds the snapshot once and shows the result.

-- ============ 1. also_like, fast ============
create or replace function public.also_like_calc()
returns table (
  file_name text, title text, rank bigint, suggested_file_name text, suggested_title text,
  suggested_series text, score numeric, why text, sheet_order integer
)
language sql stable security invoker
set enable_nestloop = off
as $fn$
 WITH b AS (
         SELECT e.file_name,
            e.title,
            e.series,
            e.sheet_order,
            array_to_string(s.tags, ', '::text) AS tags,
            "substring"(COALESCE(edition_value(e.file_name, 'connected_universe'::text), s.connected_universe), '^\s*(\d)'::text) AS universe,
                CASE COALESCE(edition_value(e.file_name, 'rating'::text), s.rating)
                    WHEN 'G'::text THEN 1
                    WHEN 'T'::text THEN 2
                    WHEN 'M'::text THEN 3
                    WHEN 'E'::text THEN 4
                    ELSE NULL::integer
                END AS heat,
                CASE
                    WHEN e.number_in_series ~ '^[0-9]+(\.[0-9]+)?$'::text THEN e.number_in_series::numeric
                    ELSE NULL::numeric
                END AS num,
            e.series = ANY (string_to_array(COALESCE(( SELECT settings.value
                   FROM settings
                  WHERE settings.key = 'ya_series'::text), ''::text), ', '::text)) AS is_ya,
            lower(COALESCE(edition_value(e.file_name, 'explicit_content'::text), yes_no(s.explicit_content), ''::text)) = 'yes'::text AS is_explicit
           FROM edition_info e
             JOIN stories s USING (story_id)
          WHERE e.language = 'English'::text AND NOT COALESCE(e.anthology_only, false) AND e.not_released_reason IS NULL
        ), cand AS (
         SELECT b.file_name,
            b.title,
            b.series,
            b.sheet_order,
            b.tags,
            b.universe,
            b.heat,
            b.num,
            b.is_ya,
            b.is_explicit
           FROM b
             JOIN edition_info e USING (file_name)
          WHERE e.publication_date <= CURRENT_DATE AND (EXISTS ( SELECT 1
                   FROM store_links l
                  WHERE l.file_name = b.file_name AND l.store = 'Payhip'::text AND (l.format = ANY (ARRAY['eBook'::text, 'Audiobook'::text, 'Paperback'::text, 'Hardcover'::text])) AND l.link_or_id ~ '/b/'::text AND NOT (EXISTS ( SELECT 1
                           FROM payhip_products p
                          WHERE p.code = "substring"(l.link_or_id, '/b/([A-Za-z0-9]+)'::text) AND p.status <> 'Live'::text)))) AND b.file_name !~ '(BX|\+|TWOSES)'::text
        ), tg0 AS (
         SELECT DISTINCT b.file_name,
            lower(btrim(t.t)) AS tag
           FROM b
             CROSS JOIN LATERAL unnest(string_to_array(b.tags, ','::text)) t(t)
          WHERE btrim(t.t) <> ''::text
        ), tg AS (
         SELECT tg0.file_name,
            tg0.tag,
                CASE
                    WHEN count(*) OVER (PARTITION BY tg0.tag) <= 15 THEN 1.0
                    WHEN count(*) OVER (PARTITION BY tg0.tag) <= 40 THEN 0.5
                    ELSE 0::numeric
                END AS w
           FROM tg0
        ), ch AS (
         SELECT DISTINCT book_characters.file_name,
            book_characters.character_id
           FROM book_characters
        ), sp AS (
         SELECT DISTINCT bc.file_name,
            lower(c.species) AS species
           FROM book_characters bc
             JOIN characters c USING (character_id)
          WHERE bc.role = 'main'::text AND COALESCE(c.species, ''::text) <> ''::text
        ), nflags AS (
         SELECT n.file_name,
            ( SELECT min(c2.num) FROM cand c2 WHERE c2.series = n.series AND c2.num > n.num) AS next_num,
            n.num IS NULL OR NOT (EXISTS ( SELECT 1 FROM cand c3 WHERE c3.series = n.series AND c3.num > n.num)) AS is_last
           FROM b n
        ), poly AS (
         SELECT file_name FROM tg WHERE tag = 'polyamory'::text
        ), chpair AS (
         SELECT a.file_name AS a_file, o.file_name AS o_file, count(*) AS n
           FROM ch a JOIN ch o ON o.character_id = a.character_id
          GROUP BY 1, 2
        ), tgpair AS (
         SELECT a.file_name AS a_file, o.file_name AS o_file,
            string_agg(a.tag, ', '::text ORDER BY a.w DESC, a.tag) FILTER (WHERE a.w > 0::numeric) AS shared_tags,
            sum(a.w) AS shared_tag_count
           FROM tg a JOIN tg o ON o.tag = a.tag
          GROUP BY 1, 2
        ), sppair AS (
         SELECT a.file_name AS a_file, o.file_name AS o_file,
            string_agg(a.species, ', '::text ORDER BY a.species) AS shared_species,
            count(*) AS n
           FROM sp a JOIN sp o ON o.species = a.species
          GROUP BY 1, 2
        ), pairs AS (
         SELECT n.file_name,
            n.title,
            n.sheet_order,
            c.file_name AS suggested_file_name,
            c.title AS suggested_title,
            c.series AS suggested_series,
            COALESCE(cp.n, 0) AS shared_characters,
            COALESCE(n.universe = c.universe, false) AS same_universe,
            tp.shared_tags,
            COALESCE(tp.shared_tag_count, 0::numeric) AS shared_tag_count,
            sq.shared_species,
            COALESCE(sq.n, 0) AS shared_species_count,
                CASE
                    WHEN n.heat IS NULL OR c.heat IS NULL THEN 0
                    WHEN n.heat = c.heat THEN 1
                    WHEN abs(n.heat - c.heat) >= 2 THEN '-3'::integer
                    ELSE 0
                END AS heat_fit,
            c.series = n.series AND c.num = nf.next_num AS next_in_series,
            nf.is_last,
            c.series IS DISTINCT FROM n.series AND c.num = 1::numeric AND COALESCE(n.universe = c.universe, false) AS book1_related,
            c.series IS DISTINCT FROM n.series AND COALESCE(n.universe = c.universe, false) AS related_series,
            c.series IS DISTINCT FROM n.series AND (n.file_name IN (SELECT file_name FROM poly)) AND (c.file_name IN (SELECT file_name FROM poly)) AS both_poly
           FROM b n
             JOIN nflags nf ON nf.file_name = n.file_name
             JOIN cand c ON c.file_name <> n.file_name AND (c.is_ya OR NOT n.is_ya) AND NOT (c.is_explicit AND NOT n.is_explicit) AND NOT (c.series = n.series AND c.num IS NOT NULL AND n.num IS NOT NULL AND c.num < n.num)
             LEFT JOIN chpair cp ON cp.a_file = n.file_name AND cp.o_file = c.file_name
             LEFT JOIN tgpair tp ON tp.a_file = n.file_name AND tp.o_file = c.file_name
             LEFT JOIN sppair sq ON sq.a_file = n.file_name AND sq.o_file = c.file_name
        ), scored AS (
         SELECT p.file_name,
            p.title,
            p.sheet_order,
            p.suggested_file_name,
            p.suggested_title,
            p.suggested_series,
            p.shared_characters,
            p.same_universe,
            p.shared_tags,
            p.shared_tag_count,
            p.shared_species,
            p.shared_species_count,
            p.heat_fit,
            p.next_in_series,
            p.is_last,
            p.book1_related,
            p.related_series,
            p.both_poly,
            (15 * COALESCE(p.next_in_series, false)::integer +
                CASE
                    WHEN p.is_last THEN 4 * p.related_series::integer + 2 * p.book1_related::integer + 8 * p.both_poly::integer
                    ELSE 6 * p.book1_related::integer
                END + 3 * p.shared_characters + 2 * p.same_universe::integer)::numeric + p.shared_tag_count + p.shared_species_count::numeric + p.heat_fit::numeric AS score,
            row_number() OVER (PARTITION BY p.file_name ORDER BY ((15 * COALESCE(p.next_in_series, false)::integer +
                CASE
                    WHEN p.is_last THEN 4 * p.related_series::integer + 2 * p.book1_related::integer + 8 * p.both_poly::integer
                    ELSE 6 * p.book1_related::integer
                END + 3 * p.shared_characters + 2 * p.same_universe::integer)::numeric + p.shared_tag_count + p.shared_species_count::numeric + p.heat_fit::numeric) DESC, p.suggested_title) AS rank
           FROM pairs p
        )
 SELECT file_name,
    title,
    rank,
    suggested_file_name,
    suggested_title,
    suggested_series,
    score,
    concat_ws('; '::text,
        CASE
            WHEN next_in_series THEN 'next book in the series'::text
            ELSE NULL::text
        END,
        CASE
            WHEN book1_related THEN 'book 1 of a related series'::text
            WHEN is_last AND related_series THEN 'related series (last book: any book can follow)'::text
            ELSE NULL::text
        END,
        CASE
            WHEN is_last AND both_poly THEN 'poly romance like this one'::text
            ELSE NULL::text
        END,
        CASE
            WHEN shared_characters > 0 THEN shared_characters || ' shared characters'::text
            ELSE NULL::text
        END,
        CASE
            WHEN same_universe THEN 'same universe'::text
            ELSE NULL::text
        END,
        CASE
            WHEN shared_tag_count > 0::numeric THEN 'themes/tropes: '::text || shared_tags
            ELSE NULL::text
        END,
        CASE
            WHEN shared_species_count > 0 THEN 'similar characters: '::text || shared_species
            ELSE NULL::text
        END,
        CASE
            WHEN heat_fit = 1 THEN 'same rating'::text
            WHEN heat_fit < 0 THEN 'rating far apart'::text
            ELSE NULL::text
        END) AS why,
    sheet_order
   FROM scored
  WHERE rank <= 8 AND score > 0::numeric
  ORDER BY sheet_order, rank;
$fn$;

create or replace view public.also_like with (security_invoker = true) as
  select file_name, title, rank, suggested_file_name, suggested_title, suggested_series, score, why, sheet_order
  from public.also_like_calc();

-- ============ 2. the two views the public key could read ============
alter view public.print_id_check set (security_invoker = true);

-- store_link_blanks (the list behind "Find store links for shown books"): now follows the reader's own rights,
-- and lists every blank link for every format of a book: eBook and paperback (as before), plus hardcover (Amazon, Payhip)
-- when the hardcover is offered, audiobook (Payhip, Audible, Apple, Barnes & Noble, Downpour) when the
-- audiobook is offered, Payhip story bible when the book has a story bible, and Payhip bundle when it has one too.
-- The extra formats no longer depend on a missing eBook / paperback link, so a book whose only gap is, say, its
-- Payhip audiobook link is listed too.
create or replace view public.store_link_blanks with (security_invoker = true) as
 SELECT g.file_name,
    g.title,
    g.language,
    x.store,
    x.format,
    x.link_type,
    ( SELECT "substring"(f.isbn, '97[89][0-9]{10}'::text) AS "substring"
           FROM formats f
          WHERE f.file_name = g.file_name AND f.format = 'eBook'::text
         LIMIT 1) AS ebook_isbn,
    "substring"(COALESCE(g.paperback_isbn, ''::text), '97[89][0-9]{10}'::text) AS paperback_isbn
   FROM store_gaps g
     CROSS JOIN LATERAL ( VALUES ('Amazon'::text,'eBook'::text,'ASIN'::text,g.amazon_ebook_asin,NOT g.below_wide_minimum), ('Apple'::text,'eBook'::text,'ID'::text,g.apple_id,NOT g.in_kindle_unlimited AND NOT g.below_wide_minimum), ('Barnes & Noble'::text,'eBook'::text,'URL'::text,g.bn_ebook_url,NOT g.in_kindle_unlimited AND NOT g.below_wide_minimum), ('Kobo'::text,'eBook'::text,'URL'::text,g.kobo_ebook_url,NOT g.in_kindle_unlimited AND NOT g.below_wide_minimum), ('Google Play'::text,'eBook'::text,'URL'::text,g.google_play_url,NOT g.in_kindle_unlimited AND NOT g.below_wide_minimum), ('Payhip'::text,'eBook'::text,'URL'::text,g.payhip_ebook_url,NOT g.in_kindle_unlimited), ('Books2Read'::text,'eBook'::text,'Universal Link'::text,g.books2read_link,NOT g.in_kindle_unlimited AND NOT g.below_wide_minimum), ('Amazon'::text,'Paperback'::text,'ASIN'::text,g.amazon_paperback_asin,g.has_paperback), ('Barnes & Noble'::text,'Paperback'::text,'URL'::text,g.bn_paperback_url,g.has_paperback), ('Payhip'::text,'Paperback'::text,'URL'::text,g.payhip_paperback_url,g.has_paperback)) x(store, format, link_type, val, applies)
  WHERE (g.release_status = ANY (ARRAY['published'::text, 'upcoming'::text])) AND x.applies AND needs_value(x.val) AND is_expected(g.language, x.store, x.format, x.link_type)
UNION ALL
 SELECT e.file_name,
    e.title,
    e.language,
    x.store,
    x.format,
    x.link_type,
    NULL::text AS ebook_isbn,
    NULL::text AS paperback_isbn
   FROM edition_info e
     CROSS JOIN LATERAL ( SELECT EXISTS ( SELECT 1 FROM formats f WHERE f.file_name = e.file_name AND f.format = 'Audiobook'::text AND NOT COALESCE(f.not_offered, false)) AS offered ) aud
     CROSS JOIN LATERAL ( SELECT ( EXISTS ( SELECT 1 FROM story_bibles sb WHERE sb.file_name = e.file_name)
                                   OR EXISTS ( SELECT 1 FROM store_links l WHERE l.file_name = e.file_name AND l.store = 'Payhip'::text AND l.format = 'Story Bible'::text AND l.link_type = 'URL'::text AND NOT needs_value(l.link_or_id)) ) AS has ) bib
     CROSS JOIN LATERAL ( VALUES
        ('Amazon'::text,'Hardcover'::text,'ASIN'::text,
           EXISTS ( SELECT 1 FROM formats f WHERE f.file_name = e.file_name AND f.format = 'Hardcover'::text AND NOT COALESCE(f.not_offered, false) AND COALESCE(lower(btrim(f.isbn)), ''::text) <> 'n/a'::text)),
        ('Payhip'::text,'Hardcover'::text,'URL'::text,
           EXISTS ( SELECT 1 FROM formats f WHERE f.file_name = e.file_name AND f.format = 'Hardcover'::text AND NOT COALESCE(f.not_offered, false) AND COALESCE(lower(btrim(f.isbn)), ''::text) <> 'n/a'::text)),
        ('Payhip'::text,'Audiobook'::text,'URL'::text, aud.offered),
        ('Audible'::text,'Audiobook'::text,'URL'::text, aud.offered),
        ('Apple'::text,'Audiobook'::text,'URL'::text, aud.offered),
        ('Barnes & Noble'::text,'Audiobook'::text,'URL'::text, aud.offered),
        ('Downpour'::text,'Audiobook'::text,'URL'::text, aud.offered),
        ('Payhip'::text,'Story Bible'::text,'URL'::text, bib.has),
        ('Payhip'::text,'Bundle'::text,'URL'::text, bib.has)
      ) x(store, format, link_type, applies)
  WHERE e.not_released_reason IS NULL
    AND NOT COALESCE(e.anthology_only, false)
    AND NOT (e.publication_date IS NULL AND e.collection_publication IS NOT NULL)
    AND x.applies
    AND is_expected(e.language, x.store, x.format, x.link_type)
    AND NOT EXISTS ( SELECT 1 FROM store_links l
                      WHERE l.file_name = e.file_name AND l.store = x.store AND l.format = x.format
                        AND l.link_type = x.link_type AND NOT needs_value(l.link_or_id));

-- ============ 3. the snapshot ============
create table if not exists public.site_snapshot (
  id integer primary key default 1 check (id = 1),
  data jsonb not null,
  built_at timestamptz not null default now()
);
comment on table public.site_snapshot is 'One row of JSON that the Payhip footer reads (public read, no public write). Rebuilt by build_site_snapshot().';
alter table public.site_snapshot enable row level security;
drop policy if exists site_snapshot_public_read on public.site_snapshot;
create policy site_snapshot_public_read on public.site_snapshot for select to anon, authenticated using (true);
revoke all on public.site_snapshot from anon, authenticated;
grant select on public.site_snapshot to anon, authenticated;

-- the "needs rebuild" mark: nobody but the functions below can see or change it
create table if not exists public.site_snapshot_state (
  id integer primary key default 1 check (id = 1),
  dirty boolean not null default true,
  marked_at timestamptz not null default now()
);
comment on table public.site_snapshot_state is 'Mark set by triggers when something the website shows changed; cleared by the rebuild. No policies on purpose: only the security-definer functions touch it.';
alter table public.site_snapshot_state enable row level security;
revoke all on public.site_snapshot_state from anon, authenticated;
insert into public.site_snapshot_state (id, dirty) values (1, true) on conflict (id) do nothing;

create or replace function public.build_site_snapshot()
returns void
language plpgsql security definer
set search_path = public, pg_temp
set statement_timeout = '110s'
as $fn$
declare
  v_snap jsonb;
begin
  -- cleared first: a change made while this runs sets it again and is picked up by the next run
  update public.site_snapshot_state set dirty = false where id = 1;

  v_snap := (
    with
    ed as (
      select ef.file_name, ef.sheet_order, ef.language, ef.title, ef.series, ef.number_in_series,
             ef.paperback_pages, ef.paperback_page_size, ef.rating, ef.word_count,
             ef.simplified_award, ef.display_tags, ef.anthology_only,
             coalesce(ef.subscription_publication, ef.publication_date) as day
        from public.editions_full ef
       where ef.not_released_reason is null
    ),
    -- Payhip products linked to each book: [format, code, product name, price, status]
    pr as (
      select x.file_name,
             jsonb_agg(jsonb_build_array(x.format, x.code, x.name, x.price_usd, x.status) order by x.format, x.code) as products
        from (
          select distinct l.file_name, l.format,
                 substring(l.link_or_id from '/b/([A-Za-z0-9]+)') as code,
                 p.name, p.price_usd, p.status
            from public.store_links l
            left join public.payhip_products p on p.code = substring(l.link_or_id from '/b/([A-Za-z0-9]+)')
           where l.store = 'Payhip' and l.link_or_id ~ '/b/([A-Za-z0-9]+)'
        ) x
       group by x.file_name
    ),
    pb as (
      select f.file_name, f.not_offered, f.isbn
        from public.formats f where f.format = 'Paperback'
    ),
    au as (
      select f.file_name, f.not_offered,
             nullif(btrim(regexp_replace(coalesce(f.runtime, ''), '\s+', ' ', 'g')), '') as runtime,
             nullif(btrim(regexp_replace(coalesce(f.narrator, ''), '\s+', ' ', 'g')), '') as narrator
        from public.formats f where f.format = 'Audiobook'
    ),
    -- picks for "A Connected World": the first four suggestions from another series
    picks as (
      select r.file_name, jsonb_agg(r.suggested_title order by r.rank) as titles
        from (
          select a.file_name, a.rank, a.suggested_title,
                 row_number() over (partition by a.file_name order by a.rank) as n
            from public.also_like a
           where a.suggested_series is distinct from (
                   select e2.series from public.editions e2 where e2.file_name = a.file_name)
        ) r
       where r.n <= 4
       group by r.file_name
    ),
    book as (
      select ed.sheet_order,
        jsonb_strip_nulls(jsonb_build_object(
          'f', ed.file_name,
          't', ed.title,
          'l', ed.language,
          's', ed.series,
          'n', case when ed.number_in_series ~ '^\s*[0-9]+(\.[0-9]+)?\s*$'
                    then floor(ed.number_in_series::numeric)::integer end,
          'd', ed.day::text,
          'an', case when coalesce(ed.anthology_only, false) then true end,
          'p', pr.products,
          -- paperback pages and size, only for a paperback that is really offered
          'pg', case
                  when coalesce(pb.not_offered, false) then null
                  when not ( coalesce(pb.isbn, '') ~ '^\s*97[89]'
                             or exists (select 1 from public.store_links l
                                         where l.file_name = ed.file_name and l.store = 'Payhip'
                                           and l.format = 'Paperback' and l.link_or_id ~ '/b/([A-Za-z0-9]+)') ) then null
                  when coalesce(ed.paperback_pages, 0) > 0
                       and lower(btrim(regexp_replace(coalesce(ed.paperback_page_size, ''), '\s+', ' ', 'g'))) not in ('', 'none', 'n/a', 'na', '-')
                    then ed.paperback_pages || ' (' || btrim(regexp_replace(ed.paperback_page_size, '\s+', ' ', 'g')) || ') pages'
                end,
          -- audiobook runtime and narrator
          'au', case
                  when au.file_name is null or coalesce(au.not_offered, false) then null
                  when lower(coalesce(au.runtime, '')) in ('', 'none', 'n/a', 'na', '-')
                    or lower(coalesce(au.narrator, '')) in ('', 'none', 'n/a', 'na', '-') then null
                  else jsonb_build_array(au.runtime, au.narrator)
                end,
          -- badges: awards, Quick Escape, and the rating ("Rated G" / "Rated T" / "Rated M" / "Rated E")
          'b', nullif(
                 coalesce((select jsonb_agg(btrim(a.x) order by a.ord)
                             from unnest(string_to_array(coalesce(ed.simplified_award, ''), '!')) with ordinality a(x, ord)
                            where btrim(a.x) <> ''), '[]'::jsonb)
                 || case when ed.word_count is not null and ed.word_count < 40000 then '["Quick Escape"]'::jsonb else '[]'::jsonb end
                 || case when ed.rating in ('G', 'T', 'M', 'E') then jsonb_build_array('Rated ' || ed.rating) else '[]'::jsonb end,
                 '[]'::jsonb),
          -- tags
          'tg', (select jsonb_agg(q.t order by q.ord)
                   from (select btrim(u.x) as t, min(u.ord) as ord
                           from unnest(string_to_array(coalesce(ed.display_tags, ''), ',')) with ordinality u(x, ord)
                          where btrim(u.x) <> ''
                          group by btrim(u.x)) q),
          'rec', case when ed.language = 'English' then picks.titles end
        )) as j
      from ed
      left join pr on pr.file_name = ed.file_name
      left join pb on pb.file_name = ed.file_name
      left join au on au.file_name = ed.file_name
      left join picks on picks.file_name = ed.file_name
    )
    select jsonb_build_object(
             'v', 1,
             'built', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             'books', coalesce(jsonb_agg(book.j order by book.sheet_order), '[]'::jsonb))
      from book
  );

  insert into public.site_snapshot (id, data, built_at) values (1, v_snap, now())
  on conflict (id) do update set data = excluded.data, built_at = excluded.built_at;
end
$fn$;

create or replace function public.rebuild_site_snapshot_if_marked()
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $fn$
begin
  if exists (select 1 from public.site_snapshot_state where id = 1 and dirty) then
    perform public.build_site_snapshot();
  end if;
end
$fn$;

create or replace function public.mark_site_snapshot()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $fn$
begin
  update public.site_snapshot_state set dirty = true, marked_at = now() where id = 1 and not dirty;
  return null;
end
$fn$;

-- nobody outside the database can run these through the API
revoke all on function public.build_site_snapshot() from public, anon, authenticated;
revoke all on function public.rebuild_site_snapshot_if_marked() from public, anon, authenticated;
revoke all on function public.mark_site_snapshot() from public, anon, authenticated;

-- ============ 4. triggers: only set the mark ============
-- (a trigger on a column list fires only when one of those columns is in the UPDATE)
drop trigger if exists site_snapshot_mark_ud on public.editions;
create trigger site_snapshot_mark_ud after insert or delete on public.editions
  for each statement execute function public.mark_site_snapshot();
drop trigger if exists site_snapshot_mark_u on public.editions;
create trigger site_snapshot_mark_u
  after update of file_name, story_id, language, title, series, number_in_series, publication_date,
                  paperback_pages, paperback_page_size, word_count, anthology_only on public.editions
  for each statement execute function public.mark_site_snapshot();

drop trigger if exists site_snapshot_mark_ud on public.stories;
create trigger site_snapshot_mark_ud after insert or delete on public.stories
  for each statement execute function public.mark_site_snapshot();
drop trigger if exists site_snapshot_mark_u on public.stories;
create trigger site_snapshot_mark_u
  after update of story_id, rating, explicit_content, spice, connected_universe, tags, display_tags on public.stories
  for each statement execute function public.mark_site_snapshot();

drop trigger if exists site_snapshot_mark_ud on public.formats;
create trigger site_snapshot_mark_ud after insert or delete on public.formats
  for each statement execute function public.mark_site_snapshot();
drop trigger if exists site_snapshot_mark_u on public.formats;
create trigger site_snapshot_mark_u
  after update of file_name, format, not_offered, isbn, narrator, runtime on public.formats
  for each statement execute function public.mark_site_snapshot();

drop trigger if exists site_snapshot_mark_ud on public.store_links;
create trigger site_snapshot_mark_ud after insert or delete on public.store_links
  for each statement execute function public.mark_site_snapshot();
drop trigger if exists site_snapshot_mark_u on public.store_links;
create trigger site_snapshot_mark_u
  after update of file_name, store, format, link_or_id on public.store_links
  for each statement execute function public.mark_site_snapshot();

drop trigger if exists site_snapshot_mark_ud on public.payhip_products;
create trigger site_snapshot_mark_ud after insert or delete on public.payhip_products
  for each statement execute function public.mark_site_snapshot();
drop trigger if exists site_snapshot_mark_u on public.payhip_products;
create trigger site_snapshot_mark_u
  after update of code, name, status on public.payhip_products
  for each statement execute function public.mark_site_snapshot();

drop trigger if exists site_snapshot_mark_ud on public.characters;
create trigger site_snapshot_mark_ud after insert or delete on public.characters
  for each statement execute function public.mark_site_snapshot();
drop trigger if exists site_snapshot_mark_u on public.characters;
create trigger site_snapshot_mark_u
  after update of character_id, species on public.characters
  for each statement execute function public.mark_site_snapshot();

drop trigger if exists site_snapshot_mark_ud on public.book_characters;
create trigger site_snapshot_mark_ud after insert or delete on public.book_characters
  for each statement execute function public.mark_site_snapshot();
drop trigger if exists site_snapshot_mark_u on public.book_characters;
create trigger site_snapshot_mark_u
  after update of file_name, character_id, role on public.book_characters
  for each statement execute function public.mark_site_snapshot();

-- small tables where any change can matter
do $do$
declare t text;
begin
  foreach t in array array['edition_differences', 'edition_awards', 'edition_release_notes', 'tag_vocab', 'settings'] loop
    execute format('drop trigger if exists site_snapshot_mark on public.%I', t);
    execute format('create trigger site_snapshot_mark after insert or update or delete on public.%I
                    for each statement execute function public.mark_site_snapshot()', t);
  end loop;
end
$do$;

-- ============ 5. pg_cron ============
-- every minute: rebuild only when marked.  00:00 UTC every day: rebuild whatever the mark says.
select cron.schedule('site-snapshot-marked', '* * * * *', 'select public.rebuild_site_snapshot_if_marked()');
select cron.schedule('site-snapshot-daily', '0 0 * * *', 'select public.build_site_snapshot()');

-- ============ 6. build it once, and show it ============
select public.build_site_snapshot();
select built_at, jsonb_array_length(data -> 'books') as books, pg_column_size(data) as bytes,
       (select count(*) from jsonb_array_elements(data -> 'books') b where b ? 'rec') as books_with_picks
  from public.site_snapshot;
