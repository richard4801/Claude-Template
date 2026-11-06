CREATE TABLE "claude_messages" (
	"id" text PRIMARY KEY NOT NULL,
	"thread_id" text NOT NULL,
	"role" text NOT NULL,
	"source" text NOT NULL,
	"text" text DEFAULT '' NOT NULL,
	"turn_id" text,
	"tool" jsonb,
	"image_key" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "claude_settings" (
	"studio_id" text PRIMARY KEY NOT NULL,
	"api_fallback" boolean DEFAULT false NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "claude_threads" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"owner_id" text NOT NULL,
	"context_kind" text NOT NULL,
	"context_id" text NOT NULL,
	"claude_session_id" text,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "claude_turns" (
	"id" text PRIMARY KEY NOT NULL,
	"thread_id" text NOT NULL,
	"owner_id" text NOT NULL,
	"text" text NOT NULL,
	"from" text NOT NULL,
	"state" text NOT NULL,
	"error" text,
	"created_at" bigint NOT NULL,
	"claimed_at" bigint,
	"last_event_at" bigint,
	"finished_at" bigint
);
--> statement-breakpoint
CREATE TABLE "oauth_clients" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"redirect_uris" jsonb NOT NULL,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "oauth_codes" (
	"code_hash" text PRIMARY KEY NOT NULL,
	"client_id" text NOT NULL,
	"client_name" text NOT NULL,
	"user_id" text NOT NULL,
	"studio_id" text NOT NULL,
	"redirect_uri" text NOT NULL,
	"code_challenge" text NOT NULL,
	"resource" text NOT NULL,
	"scopes" jsonb NOT NULL,
	"expires_at" bigint NOT NULL,
	"used_at" bigint
);
--> statement-breakpoint
CREATE TABLE "oauth_tokens" (
	"id" text PRIMARY KEY NOT NULL,
	"grant_id" text NOT NULL,
	"kind" text NOT NULL,
	"token_hash" text NOT NULL,
	"client_id" text NOT NULL,
	"client_name" text NOT NULL,
	"user_id" text NOT NULL,
	"studio_id" text NOT NULL,
	"scopes" jsonb NOT NULL,
	"audience" text NOT NULL,
	"created_at" bigint NOT NULL,
	"expires_at" bigint NOT NULL,
	"used_at" bigint,
	"last_used_at" bigint,
	"revoked_at" bigint
);
--> statement-breakpoint
ALTER TABLE "claude_messages" ADD CONSTRAINT "claude_messages_thread_id_claude_threads_id_fk" FOREIGN KEY ("thread_id") REFERENCES "public"."claude_threads"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "claude_turns" ADD CONSTRAINT "claude_turns_thread_id_claude_threads_id_fk" FOREIGN KEY ("thread_id") REFERENCES "public"."claude_threads"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "claude_messages_thread_idx" ON "claude_messages" USING btree ("thread_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "claude_threads_context_idx" ON "claude_threads" USING btree ("owner_id","context_kind","context_id");--> statement-breakpoint
CREATE INDEX "claude_turns_thread_idx" ON "claude_turns" USING btree ("thread_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "oauth_tokens_hash_idx" ON "oauth_tokens" USING btree ("token_hash");--> statement-breakpoint
CREATE INDEX "oauth_tokens_grant_idx" ON "oauth_tokens" USING btree ("grant_id");--> statement-breakpoint
CREATE INDEX "oauth_tokens_user_idx" ON "oauth_tokens" USING btree ("user_id");