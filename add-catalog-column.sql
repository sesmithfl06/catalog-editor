-- Catalog Editor: New column (button) and right-click the Projects section in the column list -> Add column...
-- Already applied in Supabase. Adds a column to editions, stories or projects, with its field_registry row (and list_columns row for "Pick one from a list").
-- A projects column always goes in the Projects section.
create or replace function public.add_catalog_column(p_table text, p_label text, p_type text, p_section text, p_after text default null, p_description text default null, p_list text default null, p_values text[] default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  col text;
  sqltype text;
  so integer;
begin
  if coalesce(public.team_role(), '') not in ('owner', 'editor') then
    raise exception 'Only owners and editors can add columns.';
  end if;
  if p_table not in ('editions', 'stories', 'projects') then
    raise exception 'A new column can only go on editions, stories or projects.';
  end if;
  if p_table = 'projects' then p_section := 'Projects'; end if;
  p_label := btrim(coalesce(p_label, ''));
  if p_label = '' then raise exception 'Give the column a name.'; end if;
  col := btrim(regexp_replace(lower(p_label), '[^a-z0-9]+', '_', 'g'), '_');
  if col !~ '^[a-z][a-z0-9_]{0,58}$' then
    raise exception 'The name must start with a letter: "%".', p_label;
  end if;
  if exists (select 1 from pg_attribute where attrelid = ('public.' || p_table)::regclass and attname = col and attnum > 0 and not attisdropped) then
    raise exception 'There is already a column "%" in %.', col, p_table;
  end if;
  if exists (select 1 from public.field_registry where lower(label) = lower(p_label)) then
    raise exception 'A column named "%" already exists.', p_label;
  end if;

  sqltype := case p_type
    when 'text' then 'text' when 'long_text' then 'text' when 'pick' then 'text'
    when 'number' then 'numeric' when 'whole_number' then 'integer'
    when 'date' then 'date' when 'yes_no' then 'boolean' when 'list' then 'text[]' end;
  if sqltype is null then raise exception 'Unknown kind of value "%".', p_type; end if;

  if p_type = 'pick' then
    p_list := btrim(coalesce(p_list, ''));
    if p_list = '' then raise exception 'Choose the list to pick from, or name a new one.'; end if;
    if p_values is not null then
      insert into public.reference_lists (list_name, value, sort_order)
      select p_list, v, (row_number() over (order by min(n)))::int * 10
        from (select btrim(x) v, n from unnest(p_values) with ordinality u(x, n)) s
       where v <> '' group by v
      on conflict (list_name, value) do nothing;
    end if;
    if not exists (select 1 from public.reference_lists where list_name = p_list) then
      raise exception 'The list "%" has no values yet.', p_list;
    end if;
  end if;

  execute format('alter table public.%I add column %I %s', p_table, col, sqltype);

  select r.sort_order into so from public.field_registry r
   where (p_after like 'ed:%' and r.table_name = 'editions' and r.column_name = substr(p_after, 4))
      or (p_after like 'st:%' and r.table_name = 'stories'  and r.column_name = substr(p_after, 4))
      or (p_after like 'one:projects:%' and r.table_name = 'projects' and r.column_name = substr(p_after, 14))
   limit 1;

  insert into public.field_registry (table_name, column_name, label, group_name, sort_order, description, filled_by, in_notion, editor_type, editor_after)
  values (p_table, col, p_label, nullif(btrim(coalesce(p_section, '')), ''), coalesce(so, 9999), nullif(btrim(coalesce(p_description, '')), ''),
          'You', false, p_type, nullif(btrim(coalesce(p_after, '')), ''));

  if p_type = 'pick' then
    insert into public.list_columns (list_name, table_name, column_name) values (p_list, p_table, col);
  end if;

  notify pgrst, 'reload schema';
  return col;
end $function$;
