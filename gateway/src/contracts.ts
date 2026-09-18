export type CustomToolSchema = { description: string; parameters: { type: 'object'; properties: Record<string, { type: 'string'|'number'|'integer'|'boolean'; minLength?: number; maxLength?: number; minimum?: number; maximum?: number; enum?: Array<string|number|boolean> }>; required?: string[]; additionalProperties: false } };
export type TurnInput = { serverId: string; sessionId: string; requestId?: string; sessionRevision?: number; turnId?: string; gatewayNonce?: number; voice?: Record<string, unknown>; npc: Record<string, unknown>; context: Record<string, unknown>; history: Array<{ role: 'user'|'assistant'; content: string }>; input: string; allowedTools: string[]; toolSchemas?: Record<string, CustomToolSchema>; toolResult?: { name: string; result: unknown } };
export type ToolCall = { name: string; arguments: Record<string, unknown> };
export type RelationshipSnapshot = { score: number; familiarity: number; trust: number; warmth: number; respect: number; fear: number; irritation: number; obligation: number; tags: string[]; updatedAt: string; sessionScore?: number; recentTreatment?: string };
export type PerformanceOutput = { emotion: 'neutral'|'warm'|'stern'|'nervous'|'urgent'|'quiet'|'menacing'; intensity: number; cadence: 'slow'|'measured'|'natural'|'brisk'; deliveryPreset: 'neutral'|'warm'|'stern'|'nervous'|'urgent'|'quiet'|'menacing'; gesture: 'none'|'greet'|'explain'|'warn'|'dismiss'; gaze: 'player'|'away'|'scan' };
export type AudioOutput = { utteranceId: string; url: string; expiresAt: string; contentType: 'audio/mpeg'; sourceNetworkId?: number; maximumDistance: number; durationMs?: number };
export type TurnOutput = { text: string; requestId?: string; toolCall?: ToolCall; audioUrl?: string; audio?: AudioOutput; performance?: PerformanceOutput; relationship?: RelationshipSnapshot; usage?: { inputTokens?: number; outputTokens?: number; provider: string; fallbackFrom?: string; queueMs?: number; promptMs?: number; completionMs?: number } };

export function validateTurn(value: unknown): TurnInput {
  if (!value || typeof value !== 'object') throw new Error('invalid_json');
  const v = value as Record<string, unknown>;
  const allowedFields = new Set(['serverId', 'sessionId', 'requestId', 'sessionRevision', 'turnId', 'gatewayNonce', 'voice', 'npc', 'context', 'history', 'input', 'allowedTools', 'toolSchemas', 'toolResult']);
  if (Object.keys(v).some(key => !allowedFields.has(key))) throw new Error('invalid_unknown_field');
  if (typeof v.serverId !== 'string' || v.serverId.length < 1 || v.serverId.length > 100 || typeof v.sessionId !== 'string' || v.sessionId.length < 16 || v.sessionId.length > 160 || typeof v.input !== 'string') throw new Error('invalid_turn');
  if (v.input.length < 1 || v.input.length > 500) throw new Error('invalid_input_length');
  if (!Array.isArray(v.allowedTools) || v.allowedTools.length > 32 || v.allowedTools.some(tool => typeof tool !== 'string' || !/^[a-z0-9_-]{1,64}$/i.test(tool))) throw new Error('invalid_tools');
  const toolSchemas = validateToolSchemas(v.toolSchemas, v.allowedTools as string[]);
  if (!Array.isArray(v.history) || v.history.length > 64 || v.history.some(entry => {
    if (!entry || typeof entry !== 'object') return true;
    const message = entry as Record<string, unknown>;
    return (message.role !== 'user' && message.role !== 'assistant') || typeof message.content !== 'string' || message.content.length > 5000 || Object.keys(message).some(key => key !== 'role' && key !== 'content');
  })) throw new Error('invalid_history');
  const toolResult = v.toolResult && typeof v.toolResult === 'object' && !Array.isArray(v.toolResult) ? v.toolResult as TurnInput['toolResult'] : undefined;
  if (v.toolResult !== undefined && !toolResult) throw new Error('invalid_tool_result');
  let toolResultSize = 0;
  if (toolResult && 'result' in toolResult) {
    const encodedResult = JSON.stringify(toolResult.result);
    toolResultSize = typeof encodedResult === 'string' ? encodedResult.length : Number.POSITIVE_INFINITY;
  }
  if (toolResult && (typeof toolResult.name !== 'string' || !/^[a-z0-9_-]{1,64}$/i.test(toolResult.name) || !v.allowedTools.includes(toolResult.name) || !('result' in toolResult) || toolResultSize > 20_000)) throw new Error('invalid_tool_result');
  if (v.requestId !== undefined && (typeof v.requestId !== 'string' || !/^[A-Za-z0-9_.:-]{8,160}$/.test(v.requestId))) throw new Error('invalid_request_id');
  for (const key of ['sessionRevision', 'gatewayNonce']) {
    if (v[key] !== undefined && (!Number.isSafeInteger(v[key]) || Number(v[key]) < 1)) throw new Error(`invalid_${key}`);
  }
  if (v.turnId !== undefined && (typeof v.turnId !== 'string' || !/^[A-Za-z0-9_.:-]{8,160}$/.test(v.turnId))) throw new Error('invalid_turn_id');
  if (v.voice !== undefined && (!v.voice || typeof v.voice !== 'object' || Array.isArray(v.voice) || JSON.stringify(v.voice).length > 10000)) throw new Error('invalid_voice');
  const requestId = typeof v.requestId === 'string' ? v.requestId : undefined;
  if (!v.npc || typeof v.npc !== 'object' || Array.isArray(v.npc) || !v.context || typeof v.context !== 'object' || Array.isArray(v.context)) throw new Error('invalid_context');
  const npc = v.npc as Record<string, unknown>;
  const context = v.context as Record<string, unknown>;
  return { serverId: v.serverId, sessionId: v.sessionId, requestId, sessionRevision: v.sessionRevision as number | undefined, turnId: v.turnId as string | undefined, gatewayNonce: v.gatewayNonce as number | undefined, voice: v.voice as Record<string, unknown> | undefined, npc, context, history: v.history as TurnInput['history'], input: v.input, allowedTools: v.allowedTools as string[], toolSchemas, toolResult };
}

function validateToolSchemas(value: unknown, allowedTools: string[]): Record<string, CustomToolSchema> | undefined {
  if (value === undefined) return undefined;
  if (Array.isArray(value) && value.length === 0) return undefined;
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length > 32 || JSON.stringify(value).length > 20_000) throw new Error('invalid_tool_schemas');
  const schemas = value as Record<string, CustomToolSchema>;
  for (const [name, schema] of Object.entries(schemas)) {
    if (!allowedTools.includes(name) || !/^[a-z0-9_-]{1,64}$/i.test(name) || !schema || typeof schema.description !== 'string' || schema.description.length < 1 || schema.description.length > 300) throw new Error('invalid_tool_schemas');
    const parameters = schema.parameters;
    if (!parameters || parameters.type !== 'object' || parameters.additionalProperties !== false || !parameters.properties) throw new Error('invalid_tool_schemas');
    if (Array.isArray(parameters.properties) && parameters.properties.length === 0) {
      parameters.properties = {};
    }
    if (typeof parameters.properties !== 'object' || Array.isArray(parameters.properties) || Object.keys(parameters.properties).length > 24) throw new Error('invalid_tool_schemas');
    let required = parameters.required ?? [];
    if (typeof required === 'object' && required !== null && !Array.isArray(required) && Object.keys(required).length === 0) {
      required = [];
      parameters.required = required;
    }
    if (!Array.isArray(required) || required.some(key => typeof key !== 'string' || !(key in parameters.properties))) throw new Error('invalid_tool_schemas');
    for (const [key, property] of Object.entries(parameters.properties)) {
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(key) || !property || !['string', 'number', 'integer', 'boolean'].includes(property.type)) throw new Error('invalid_tool_schemas');
      if (property.enum !== undefined) {
        let enumVal = property.enum;
        if (typeof enumVal === 'object' && enumVal !== null && !Array.isArray(enumVal) && Object.keys(enumVal).length === 0) {
          enumVal = [];
          property.enum = enumVal;
        }
        if (!Array.isArray(enumVal) || enumVal.length > 50) throw new Error('invalid_tool_schemas');
      }
    }
  }
  return schemas;
}
