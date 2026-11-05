-- Story bible price: a real, editable column in Supabase (it used to be read from the Payhip product list).
-- Run once in Supabase -> SQL Editor. Safe to run again.

alter table public.story_bibles add column if not exists price_usd numeric;

-- Copy the price each story bible has now (from its Payhip link) so nothing is lost.
update public.story_bibles sb
   set price_usd = x.price_usd
  from (
    select l.file_name, max(p.price_usd) as price_usd
      from public.store_links l
      join public.payhip_products p on p.code = substring(l.link_or_id from '/b/([A-Za-z0-9]+)')
     where l.store = 'Payhip' and l.format = 'Story Bible'
     group by l.file_name
  ) x
 where x.file_name = sb.file_name and sb.price_usd is null;

-- Name and place the column in the editor's column list.
insert into public.field_registry (table_name, column_name, sort_order, label, group_name, side, filled_by, new_book_pass, in_notion)
select 'story_bibles', 'price_usd', 50, 'Price ($)', 'Story Bible', 'Laurelle (book side)', 'You', 1, false
 where not exists (select 1 from public.field_registry where table_name = 'story_bibles' and column_name = 'price_usd');
