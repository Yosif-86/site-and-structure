-- Payment requests no longer ask for the student's Zain Cash / Qi Card
-- number (2026-10-05): the proof screenshot is enough. Edits the live
-- submit_paid_enrollment in place so only the "detail must be filled"
-- check changes (it may still be sent, up to 64 characters).
do $$
declare
  d text;
begin
  d := pg_get_functiondef(
    'public.submit_paid_enrollment(text, text, text, text, text)'::regprocedure);
  if position($q$coalesce(trim(p_detail), '') = '' or length(p_detail) > 64$q$ in d) = 0 then
    raise exception 'submit_paid_enrollment check not found: function differs from add-oct05-fixes.sql';
  end if;
  d := replace(d,
    $q$coalesce(trim(p_detail), '') = '' or length(p_detail) > 64$q$,
    $q$length(coalesce(p_detail, '')) > 64$q$);
  execute d;
end;
$$;

-- Check: should say true.
select 'sender number optional' as item,
  position('length(coalesce(p_detail, '''')) > 64' in pg_get_functiondef(
    'public.submit_paid_enrollment(text, text, text, text, text)'::regprocedure)) > 0 as ok;
