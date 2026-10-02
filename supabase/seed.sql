-- Seeds the throwaway database CI builds (`supabase start`), never a hosted one. Production sets these two secrets once, by hand:
--   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1', 'edge_functions_url');
--   select vault.create_secret('<long random string>', 'db_events_secret');
-- db_events_secret must equal DB_EVENTS_SECRET in the Edge Functions secrets.
select vault.create_secret('http://host.docker.internal:55421/functions/v1', 'edge_functions_url');
select vault.create_secret('local-dev-db-events-secret', 'db_events_secret');
-- Purchases here are sandbox ones (the staging RevenueCat project); production leaves this unset
-- (apply_purchase_event defaults to PRODUCTION), staging gets it from scripts/sync-vault.sh.
select vault.create_secret('SANDBOX', 'purchase_environment');

-- A staff admin for the throwaway database.
insert into private.staff (email, role) values ('dev@drafft.local', 'admin');
