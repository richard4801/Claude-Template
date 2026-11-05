CREATE TABLE IF NOT EXISTS "prompt_script_rules" (
	"studio_id" text NOT NULL,
	"script_id" text NOT NULL,
	"rules" jsonb NOT NULL,
	"known_defaults" jsonb NOT NULL,
	"updated_by" text,
	"updated_at" bigint NOT NULL,
	CONSTRAINT "prompt_script_rules_studio_id_script_id_pk" PRIMARY KEY("studio_id","script_id")
);
