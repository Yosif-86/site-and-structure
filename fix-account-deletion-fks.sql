-- "Delete account" (api/delete-account.js) deletes the auth user and relies on
-- foreign keys to clean up. These FKs were NO ACTION, so deletion FAILED for:
--   * any student who ever redeemed a discount code
--   * any teacher (teacher_invites.used_by)
--   * admins who created invites / discount codes / approved enrollments
-- Fix: a user's own redemptions go with them (CASCADE); references that are
-- just "who did this" history keep the row and drop the pointer (SET NULL).

do $$
declare
  spec record;
  cname text;
begin
  for spec in
    select * from (values
      ('discount_code_redemptions', 'user_id',     'public.profiles', 'cascade'),
      ('discount_codes',            'created_by',  'public.profiles', 'set null'),
      ('teacher_invites',           'created_by',  'public.profiles', 'set null'),
      ('teacher_invites',           'used_by',     'public.profiles', 'set null'),
      ('enrollments',               'approved_by', 'auth.users',      'set null')
    ) as t(tbl, col, ref, action)
  loop
    select c.conname into cname
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f'
      and c.conrelid = ('public.' || spec.tbl)::regclass
      and a.attname = spec.col
      and array_length(c.conkey, 1) = 1;

    if cname is null then
      raise exception 'FK not found on %.%', spec.tbl, spec.col;
    end if;

    if spec.action = 'set null' then
      execute format('alter table public.%I alter column %I drop not null', spec.tbl, spec.col);
    end if;

    execute format('alter table public.%I drop constraint %I', spec.tbl, cname);
    execute format(
      'alter table public.%I add constraint %I foreign key (%I) references %s(id) on delete %s',
      spec.tbl, cname, spec.col, spec.ref, spec.action);
  end loop;
end $$;
