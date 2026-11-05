-- Fixes "Make footer code" timing out.
-- Cause: the also_like view took about 36 seconds; Supabase stops requests from the signed-in app after 8 seconds.
-- Fix: same suggestions (same books, same order, same scores), worked out with joins instead of repeated look-ups,
-- and run inside a function that turns off nested-loop joins, which the planner wrongly picked for it.
-- Only difference: inside the "why" text, "similar characters: a, b" is now in alphabetical order.
-- Run once in Supabase -> SQL Editor.

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
          WHERE COALESCE(e.payhip_publication, e.subscription_publication, e.publication_date) <= CURRENT_DATE AND (EXISTS ( SELECT 1
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
