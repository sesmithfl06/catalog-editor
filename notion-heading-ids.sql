-- Notion heading links: run once in the Supabase SQL Editor (safe to run again).
-- Adds two columns to notion_pages that the notion-sync Edge Function fills at every sync of a book's page:
--   shared_heading_id: block id of the "🔄 Shared with Supabase" heading
--   story_heading_id:  block id of the Story details heading inside the "📚 From Supabase" box (the box is rebuilt
--                      at every sync, so this changes each time; empty when the book has no story lists)
-- The Catalog Editor adds #<block id> to notion_page_url, so right-click → "Open this book's Notion page" jumps to that heading.
alter table public.notion_pages add column if not exists shared_heading_id text;
alter table public.notion_pages add column if not exists story_heading_id text;
notify pgrst, 'reload schema';
