CREATE TABLE "edit_ops" (
	"id" serial PRIMARY KEY NOT NULL,
	"session_id" text NOT NULL,
	"revision" integer NOT NULL,
	"author" text NOT NULL,
	"kind" text NOT NULL,
	"label" text NOT NULL,
	"patch" jsonb NOT NULL,
	"inverse" jsonb NOT NULL,
	"undoes" integer,
	"undone" integer DEFAULT 0 NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "edit_sessions" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"owner_id" text NOT NULL,
	"take_id" text NOT NULL,
	"base_version_id" text,
	"project" jsonb NOT NULL,
	"revision" integer DEFAULT 0 NOT NULL,
	"status" text DEFAULT 'open' NOT NULL,
	"pending" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"updated_by" text NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX "edit_ops_session_idx" ON "edit_ops" USING btree ("session_id","id");--> statement-breakpoint
CREATE INDEX "edit_sessions_take_idx" ON "edit_sessions" USING btree ("studio_id","take_id","updated_at");