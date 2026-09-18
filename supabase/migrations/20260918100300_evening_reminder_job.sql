-- Every five minutes: claim what is due and, only if there is any, hand it to
-- the Edge Function that talks to Apple.
--
-- Most ticks find nothing and stop at the query. The function URL and the
-- bearer secret it expects come from Vault at run time, so this file holds
-- nothing sensitive and the same job works locally and hosted. Seeding the two
-- Vault entries is a once-per-project step; docs/RELEASING.md has it. Until
-- they exist the job runs, claims, and posts nowhere — the null guard below —
-- which is visible as claim rows with sent_at null.
--
-- `materialized` because work() has side effects and is named twice; it must
-- run exactly once per tick.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.schedule('evening-reminder', '*/5 * * * *', $job$
  with work as materialized (
    select * from public.evening_reminder_work()
  ),
  target as (
    select (select decrypted_secret from vault.decrypted_secrets
             where name = 'evening_reminder_url')    as url,
           (select decrypted_secret from vault.decrypted_secrets
             where name = 'evening_reminder_secret') as secret
  )
  select net.http_post(
           url     := target.url,
           headers := jsonb_build_object(
                        'Content-Type',  'application/json',
                        'Authorization', 'Bearer ' || target.secret),
           body    := jsonb_build_object('work', (select jsonb_agg(to_jsonb(w)) from work w)))
    from target
   where exists (select 1 from work)
     and target.url is not null
     and target.secret is not null;
$job$);
