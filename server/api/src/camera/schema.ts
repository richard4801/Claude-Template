// Camera sessions (Directed camera mode), their assets and transcript, and MCP personal access tokens
// (plans/api.md "MCP & camera sessions", plans/mcp-bridge.md). Migration 0008. Re-exported from db/schema.ts.
import { bigint, index, integer, jsonb, doublePrecision, pgTable, text, uniqueIndex } from 'drizzle-orm/pg-core';

const ms = (name: string) => bigint(name, { mode: 'number' });

export type Vec3 = [number, number, number];
export type CamKey = { t: number; position: Vec3; target?: Vec3; focalMm?: number; rollDeg?: number; ease?: 'linear' | 'in' | 'out' | 'in_out' };
export type CharKey = { t: number; position: Vec3; facingDeg?: number; action?: string };
export type CameraPath = { keyframes: CamKey[]; cuts?: number[]; sensorMm?: number };
export type CharacterBlocking = { modelId: string; keyframes: CharKey[]; note?: string };
export type Blocking = { characters: CharacterBlocking[] };
export type CastMember = { modelId: string; role?: string; heightM?: number };
export type CameraPresets = { rig?: string; move?: string; angle?: string; intensity?: number };
export type CameraStatus = 'drafting' | 'blocking' | 'rendering' | 'ready' | 'generating' | 'done' | 'failed';
export type ShotDraftRow = {
  id: string; state: 'draft'; source: 'suite' | 'camera'; prompt: string; targetModel: string; durationSec: number; aspect: string;
  estimate: { usd: number; tokens: number }; camera: Record<string, unknown>; createdAt: number;
  /** The suite ShotRequest to send when the owner presses Generate (POST /v1/suite/shots). */
  request?: Record<string, unknown>; warnings?: string[];
};

export const cameraSessions = pgTable('camera_sessions', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  ownerId: text('owner_id').notNull(),
  title: text('title').notNull(),
  brief: text('brief').notNull().default(''),
  status: text('status').notNull().$type<CameraStatus>(),
  aspect: text('aspect').notNull(),
  fps: integer('fps').notNull(),
  durationSec: doublePrecision('duration_sec').notNull(),
  targetModel: text('target_model'),
  presets: jsonb('presets').$type<CameraPresets>().notNull(),
  characters: jsonb('characters').$type<CastMember[]>().notNull(),
  cameraPath: jsonb('camera_path').$type<CameraPath>(),
  blocking: jsonb('blocking').$type<Blocking>(),
  shotDraft: jsonb('shot_draft').$type<ShotDraftRow>(),
  /** The in-app chat's Claude conversation (append-only, full content blocks so thinking and caching survive). */
  directorHistory: jsonb('director_history').$type<unknown[]>().notNull().default([]),
  revision: integer('revision').notNull().default(1),
  createdAt: ms('created_at').notNull(),
  updatedAt: ms('updated_at').notNull(),
}, t => [index('camera_sessions_studio_idx').on(t.studioId, t.updatedAt)]);

export type CameraAssetKind = 'greybox' | 'depth' | 'pose' | 'tracks' | 'keyframe_start' | 'keyframe_mid' | 'keyframe_end' | 'still' | 'preview'
  | 'camera_json' | 'characters_json' | 'blend';

export const cameraAssets = pgTable('camera_assets', {
  id: text('id').primaryKey(),
  sessionId: text('session_id').notNull().references(() => cameraSessions.id, { onDelete: 'cascade' }),
  studioId: text('studio_id').notNull(),
  kind: text('kind').notNull().$type<CameraAssetKind>(),
  label: text('label'),
  storageKey: text('storage_key').notNull(),
  contentType: text('content_type').notNull(),
  bytes: bigint('bytes', { mode: 'number' }),
  state: text('state').notNull().$type<'pending' | 'ready'>(),
  source: text('source').notNull().$type<'app' | 'mcp' | 'relay' | 'chat'>(),
  createdBy: text('created_by'),
  createdAt: ms('created_at').notNull(),
}, t => [index('camera_assets_session_idx').on(t.sessionId, t.createdAt)]);

export const cameraMessages = pgTable('camera_messages', {
  id: text('id').primaryKey(),
  sessionId: text('session_id').notNull().references(() => cameraSessions.id, { onDelete: 'cascade' }),
  role: text('role').notNull().$type<'user' | 'assistant' | 'tool'>(),
  source: text('source').notNull().$type<'app' | 'chat' | 'mcp'>(),
  text: text('text').notNull(),
  tool: jsonb('tool').$type<{ name: string; ok: boolean; summary: string }>(),
  createdAt: ms('created_at').notNull(),
}, t => [index('camera_messages_session_idx').on(t.sessionId, t.createdAt)]);

/** Personal access tokens for the MUSE MCP server (owner only). Only a sha256 of the token is stored. */
export const mcpTokens = pgTable('mcp_tokens', {
  id: text('id').primaryKey(),
  studioId: text('studio_id').notNull(),
  userId: text('user_id').notNull(),
  name: text('name').notNull(),
  tokenHash: text('token_hash').notNull(),
  prefix: text('prefix').notNull(),
  createdAt: ms('created_at').notNull(),
  expiresAt: ms('expires_at'),
  lastUsedAt: ms('last_used_at'),
  revokedAt: ms('revoked_at'),
}, t => [uniqueIndex('mcp_tokens_hash_idx').on(t.tokenHash), index('mcp_tokens_user_idx').on(t.userId)]);
