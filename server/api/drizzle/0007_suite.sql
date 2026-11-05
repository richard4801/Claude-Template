CREATE TABLE IF NOT EXISTS "suite_settings" (
	"studio_id" text PRIMARY KEY NOT NULL,
	"models" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"ladder" jsonb,
	"cap_per_job" double precision,
	"cap_per_day" double precision,
	"updated_by" text,
	"updated_at" bigint NOT NULL
);
