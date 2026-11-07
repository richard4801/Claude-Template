CREATE TABLE IF NOT EXISTS "suite_rigs" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"rig" jsonb NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
ALTER TABLE "jobs" ADD COLUMN IF NOT EXISTS "draft" jsonb;--> statement-breakpoint
ALTER TABLE "models" ADD COLUMN IF NOT EXISTS "default_rig" jsonb;--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN IF NOT EXISTS "draft" jsonb;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "suite_rigs_studio_idx" ON "suite_rigs" USING btree ("studio_id","user_id");