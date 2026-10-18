-- Upstream's 3.3.4 adds cf_userAgent for sqlite and mysql only (update.xml has
-- no pgsql section); db_schema/postgresql.sql has it.
INSERT INTO settings (key, val) SELECT 'cf_userAgent', '' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'cf_userAgent');
