CREATE TABLE IF NOT EXISTS "edit_templates" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"template_id" text NOT NULL,
	"name" text NOT NULL,
	"kind" text NOT NULL,
	"target" text NOT NULL,
	"level" text NOT NULL,
	"spec" jsonb NOT NULL,
	"preview_upload" text,
	"reference_upload" text,
	"source" jsonb,
	"by" text NOT NULL,
	"version" integer DEFAULT 1 NOT NULL,
	"seed_version" integer,
	"deleted_at" bigint,
	"created_by" text,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "edit_templates_studio_template_idx" ON "edit_templates" USING btree ("studio_id","template_id");