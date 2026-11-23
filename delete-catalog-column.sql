-- Catalog Editor: right-click a column heading in the Projects section -> Delete column...
-- Already applied in Supabase. Drops the column (and its field_registry / list_columns rows).
-- Refuses Plot Order, key columns, anything outside the Projects section, and columns a view still uses.
create or replace function public.delete_catalog_column(p_table text, p_column text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.field_registry%rowtype;
  deps text;
begin
  if coalesce(public.team_role(), '') not in ('owner', 'editor') then
    raise exception 'Only owners and editors can delete columns.';
  end if;
  select * into r from public.field_registry where table_name = p_table and column_name = p_column limit 1;
  if not found or coalesce(r.group_name, '') <> 'Projects' then
    raise exception 'Only columns in the Projects section can be deleted.';
  end if;
  if p_table not in ('projects', 'editions', 'stories') or p_column in ('id', 'file_name', 'story_id', 'plot', 'created_at', 'updated_at') then
    raise exception 'The column "%" can''t be deleted.', coalesce(r.label, p_column);
  end if;
  select string_agg(distinct v.relname, ', ') into deps
    from pg_depend d join pg_rewrite rw on rw.oid = d.objid join pg_class v on v.oid = rw.ev_class
    join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
   where d.refobjid = ('public.' || p_table)::regclass and a.attname = p_column and v.oid <> d.refobjid;
  if deps is not null then
    raise exception '"%" is used by % in Supabase, so it wasn''t deleted. Ask Claude to take it out of those first.', coalesce(r.label, p_column), deps;
  end if;
  execute format('alter table public.%I drop column %I', p_table, p_column);
  delete from public.list_columns where table_name = p_table and column_name = p_column;
  delete from public.field_registry where table_name = p_table and column_name = p_column;
  notify pgrst, 'reload schema';
  return coalesce(r.label, p_column);
end $function$;
revoke all on function public.delete_catalog_column(text, text) from public, anon;
grant execute on function public.delete_catalog_column(text, text) to authenticated;
