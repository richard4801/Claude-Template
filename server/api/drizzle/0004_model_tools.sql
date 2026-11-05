CREATE TABLE "tool_runs" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"model_id" text NOT NULL,
	"kind" text NOT NULL,
	"state" text NOT NULL,
	"options" jsonb NOT NULL,
	"engines" jsonb NOT NULL,
	"models" jsonb NOT NULL,
	"items" jsonb NOT NULL,
	"estimate" double precision NOT NULL,
	"cost" double precision DEFAULT 0 NOT NULL,
	"progress" double precision DEFAULT 0 NOT NULL,
	"phase" text DEFAULT '' NOT NULL,
	"error" text,
	"outfit_id" text,
	"created_by" text,
	"created_at" bigint NOT NULL,
	"finished_at" bigint,
	"applied_at" bigint
);
--> statement-breakpoint
ALTER TABLE "models" ADD COLUMN "archived_at" bigint;--> statement-breakpoint
ALTER TABLE "models" ADD COLUMN "sheet_versions" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "outfits" ADD COLUMN "faces" jsonb;--> statement-breakpoint
ALTER TABLE "studio_settings" ADD COLUMN "image_models" jsonb;--> statement-breakpoint
CREATE INDEX "tool_runs_studio_idx" ON "tool_runs" USING btree ("studio_id","created_at");--> statement-breakpoint
-- Model tools (2026-11-04): the character sheet has a 7th image, the face close-up turned three-quarters ("faceTq"), appended last.
UPDATE "models" SET "slots" = "slots" || '[{"key":"faceTq","image":null,"source":"upload","busy":false}]'::jsonb WHERE NOT ("slots" @> '[{"key":"faceTq"}]'::jsonb);
