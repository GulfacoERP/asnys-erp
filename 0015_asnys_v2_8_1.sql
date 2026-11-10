-- Asnys ERP v2.8.1 — one link between tenders and projects
-- A tender records the project it became (tenders.project_id) and a project records the tender it came from
-- (projects.tender_id). Two database links between the same tables made Supabase refuse pages that show a tender's
-- project ("more than one relationship was found for 'tenders' and 'projects'"). The project keeps its tender_id, but it
-- is no longer a database link; a trigger clears it when a tender is deleted, which is what the link did. Run after 0014.

alter table public.projects drop constraint if exists projects_tender_id_fkey;

create or replace function public.clear_project_tender() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update projects set tender_id = null where tender_id = old.id;
  return old;
end $$;
drop trigger if exists tenders_clear_project on public.tenders;
create trigger tenders_clear_project after delete on public.tenders for each row execute function public.clear_project_tender();

-- Tell Supabase's API to re-read the links now.
notify pgrst, 'reload schema';
