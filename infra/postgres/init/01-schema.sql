-- AutoForge / NexusOps - PostgreSQL init script
-- Creates the "ops" schema and a least-privilege role "ops_writer".
-- Empty tables are added by later phases; this file only establishes
-- the schema and role now.

CREATE SCHEMA IF NOT EXISTS ops;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ops_writer') THEN
    CREATE ROLE ops_writer LOGIN PASSWORD '${OPS_WRITER_PASSWORD}';
  END IF;
END
$$;

GRANT USAGE ON SCHEMA ops TO ops_writer;
GRANT CREATE ON SCHEMA ops TO ops_writer;

-- Default privileges for future tables in the ops schema (tables added later)
ALTER DEFAULT PRIVILEGES IN SCHEMA ops
  GRANT INSERT, SELECT, UPDATE, DELETE ON TABLES TO ops_writer;
