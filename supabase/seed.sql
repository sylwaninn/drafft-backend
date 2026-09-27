-- Local development only (`supabase db reset`). Production sets these two secrets once, by hand:
--   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1', 'edge_functions_url');
--   select vault.create_secret('<long random string>', 'db_events_secret');
-- db_events_secret must equal DB_EVENTS_SECRET in the Edge Functions secrets.
select vault.create_secret('http://host.docker.internal:55421/functions/v1', 'edge_functions_url');
select vault.create_secret('local-dev-db-events-secret', 'db_events_secret');

-- sophros (the team's dashboard) run locally signs in as this admin (its AUTH_MODE=dev).
insert into private.staff (email, role) values ('dev@drafft.local', 'admin');
