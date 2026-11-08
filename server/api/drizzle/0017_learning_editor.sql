CREATE TABLE "edit_corrections" (
	"id" serial PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"session_id" text NOT NULL,
	"take_id" text NOT NULL,
	"op_id" integer NOT NULL,
	"claude_op_id" integer NOT NULL,
	"kind" text NOT NULL,
	"area" text NOT NULL,
	"what" text NOT NULL,
	"context" jsonb NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "edit_gaps" (
	"id" serial PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"key" text NOT NULL,
	"kind" text NOT NULL,
	"what" text NOT NULL,
	"count" integer DEFAULT 0 NOT NULL,
	"examples" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"seen" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"first_at" bigint NOT NULL,
	"last_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "edit_recipes" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"origin" text NOT NULL,
	"reference_id" text,
	"take_id" text,
	"name" text DEFAULT '' NOT NULL,
	"summary" text DEFAULT '' NOT NULL,
	"tags" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"features" jsonb NOT NULL,
	"recipe" jsonb NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "playbook_rules" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"text" text NOT NULL,
	"area" text DEFAULT 'other' NOT NULL,
	"source" text NOT NULL,
	"pinned" boolean DEFAULT false NOT NULL,
	"evidence" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
ALTER TABLE "edit_ops" ADD COLUMN "meta" jsonb;--> statement-breakpoint
CREATE INDEX "edit_corrections_studio_idx" ON "edit_corrections" USING btree ("studio_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "edit_gaps_key_idx" ON "edit_gaps" USING btree ("studio_id","key");--> statement-breakpoint
CREATE INDEX "edit_recipes_studio_idx" ON "edit_recipes" USING btree ("studio_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "edit_recipes_ref_idx" ON "edit_recipes" USING btree ("studio_id","reference_id");--> statement-breakpoint
CREATE UNIQUE INDEX "edit_recipes_take_idx" ON "edit_recipes" USING btree ("studio_id","take_id");--> statement-breakpoint
CREATE INDEX "playbook_rules_studio_idx" ON "playbook_rules" USING btree ("studio_id","updated_at");