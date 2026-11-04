-- dataverse-sync keeps verify_jwt ON, so the nightly job must also present a
-- valid project JWT for the gateway: the public anon key (the same key every
-- browser page already uses -- not a secret). The x-sync-secret header from
-- Vault is what the function itself checks to authorize the run.
select cron.schedule(
  'crm-nightly-sync',
  '0 3 * * *',
  $job$
    select net.http_post(
      url := 'https://dhabmvpngjgrepyklius.supabase.co/functions/v1/dataverse-sync',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRoYWJtdnBuZ2pncmVweWtsaXVzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY2ODgxNzIsImV4cCI6MjEwMjI2NDE3Mn0.GzNEeF-gFrfl0Da3KL0XT7nbRUZX8xerNd67M2icUPc',
        'x-sync-secret', public.crm_sync_secret()
      ),
      body := '{"chain": true}'::jsonb,
      timeout_milliseconds := 15000
    );
  $job$
);
