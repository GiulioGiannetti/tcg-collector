# Supabase database

The app's server side (tables, views, functions, security rules and scheduled jobs) lives in the
Supabase project. `schema/` holds a copy of it so changes can be reviewed and recovered:

- `schema/public.sql`: tables, views, functions and row-level security policies (`supabase db dump`)
- `schema/cron.sql`: the scheduled jobs (`cron.job`)

The copy is refreshed weekly and on demand by `.github/workflows/schema-snapshot.yml` (Actions →
"Database schema snapshot" → Run workflow). It is schema only: no rows and no user data. API keys
stay in Supabase Vault and are only referenced by name.
