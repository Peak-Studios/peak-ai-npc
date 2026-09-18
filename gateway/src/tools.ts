import type { CustomToolSchema } from './contracts.js';
type JsonSchema = CustomToolSchema['parameters'];

const definitions: Record<string, { description: string; parameters: JsonSchema }> = {
  get_shop_catalog: { description: 'Read the configured catalog for the NPC shop.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  get_shop_stock: { description: 'Read current stock for the NPC shop.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  player_has_item: { description: 'Check whether the player has an item using authoritative inventory data.', parameters: { type: 'object', properties: { item: { type: 'string', minLength: 1, maxLength: 64 }, quantity: { type: 'number', minimum: 1, maximum: 10000 } }, required: ['item', 'quantity'], additionalProperties: false } },
  create_purchase_quote: { description: 'Create a quote. Never claim an item was purchased until confirm_purchase succeeds.', parameters: { type: 'object', properties: { item: { type: 'string' }, quantity: { type: 'number', minimum: 1, maximum: 20 } }, required: ['item', 'quantity'], additionalProperties: false } },
  confirm_purchase: { description: 'Confirm the pending purchase only after the player explicitly agrees.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  offer_mission: { description: 'Offer a configured mission to the player.', parameters: { type: 'object', properties: { missionId: { type: 'string' } }, required: ['missionId'], additionalProperties: false } },
  accept_mission: { description: 'Accept a previously offered configured mission.', parameters: { type: 'object', properties: { missionId: { type: 'string' } }, required: ['missionId'], additionalProperties: false } },
  npc_face_player: { description: 'Make the NPC face the player.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_follow_player: { description: 'Request the configured NPC follow the player.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_flee: { description: 'Make the configured NPC flee from the player.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_surrender: { description: 'Make the configured NPC raise their hands and surrender.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_stop: { description: 'Stop the configured NPC current action.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_react: { description: 'Show one grounded social reaction to the player. Choose a response that fits the NPC personality, the player tone, and the observed situation; do not overreact to casual profanity.', parameters: { type: 'object', properties: { reaction: { type: 'string', enum: ['approach', 'offended', 'angry', 'dismissive', 'friendly', 'cautious'] } }, required: ['reaction'], additionalProperties: false } },
  npc_walk_to_position: { description: 'Walk the NPC to a nearby position. Coordinates must be within the NPC action radius.', parameters: { type: 'object', properties: { x: { type: 'number' }, y: { type: 'number' }, z: { type: 'number' } }, required: ['x', 'y', 'z'], additionalProperties: false } },
  npc_sit: { description: 'Make the NPC sit using a safe ambient scenario.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_point: { description: 'Make the NPC point using a safe ambient scenario.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_enter_vehicle: { description: 'Make the NPC enter the nearest suitable vehicle.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_leave_vehicle: { description: 'Make the NPC leave its current vehicle.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_call_service: { description: 'Request an approved emergency service.', parameters: { type: 'object', properties: { service: { type: 'string' } }, required: ['service'], additionalProperties: false } },
  police_respond_exit: { description: 'Respond to an existing verified officer request to exit this stationary vehicle. Acceptance permits only leaving the current driver seat.', parameters: { type: 'object', properties: { accepted: { type: 'boolean' } }, required: ['accepted'], additionalProperties: false } },
  sell_item_to_shop: { description: 'Sell an item from the player inventory to the shopkeeper. Player must have the item and quantity.', parameters: { type: 'object', properties: { item: { type: 'string', minLength: 1, maxLength: 64 }, quantity: { type: 'number', minimum: 1, maximum: 100 } }, required: ['item', 'quantity'], additionalProperties: false } },
  npc_call_police: { description: 'Contact police dispatch (911) regarding an observed crime, suspicious behavior, or threat.', parameters: { type: 'object', properties: { reason: { type: 'string', minLength: 1, maxLength: 256 } }, required: ['reason'], additionalProperties: false } },
  npc_call_ems: { description: 'Contact emergency medical services (311) or dispatch an ambulance for an injured or incapacitated citizen.', parameters: { type: 'object', properties: { condition: { type: 'string', minLength: 1, maxLength: 256 } }, required: ['condition'], additionalProperties: false } },
  medical_triage_player: { description: 'Read this player\'s observable health for roleplay assessment. Does not reveal records, diagnose wounds, or perform treatment.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  medical_heal_player: { description: 'Guide the player to the installed hospital check-in workflow. Never changes health or revives; do not claim treatment completed.', parameters: { type: 'object', properties: { treatmentType: { type: 'string', enum: ['first_aid', 'full_heal'] } }, required: ['treatmentType'], additionalProperties: false } },
  medical_provide_supplies: { description: 'Offer a server-priced quote for owner-allowlisted medical supplies. The player must explicitly confirm; this tool never grants items.', parameters: { type: 'object', properties: { item: { type: 'string', minLength: 1, maxLength: 64 }, quantity: { type: 'integer', minimum: 1, maximum: 20 } }, required: ['item', 'quantity'], additionalProperties: false } },
  police_check_warrants: { description: 'Privately check only the interacting citizen\'s active warrant status through a qualified self-service records adapter. Unavailable records are unknown, never a clean record.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  police_demand_id: { description: 'Privately read the interacting citizen display name. This does not verify an identity document, license, or police credential.', parameters: { type: 'object', properties: {}, additionalProperties: false } },
  npc_crouch: { description: 'Crouch down or stand back up to match the player or sneak.', parameters: { type: 'object', properties: { enable: { type: 'boolean' } }, additionalProperties: false } },
  npc_perform_move: { description: 'Perform a physical gesture, move, or roleplay action (nod, shake_head, wave, shrug, cross_arms, cheer, salute, smoke, drink, sit, point, crouch, stand).', parameters: { type: 'object', properties: { move: { type: 'string', enum: ['nod', 'shake_head', 'wave', 'shrug', 'cross_arms', 'cheer', 'salute', 'smoke', 'drink', 'sit', 'point', 'crouch', 'stand'] } }, required: ['move'], additionalProperties: false } },
  npc_look_at: { description: 'Look directly at the player for a bounded interval.', parameters: { type: 'object', properties: { durationMs: { type: 'integer', minimum: 500, maximum: 10000 } }, additionalProperties: false } }
};

export function providerTools(allowedTools: string[], custom: Record<string, CustomToolSchema> = {}) {
  return allowedTools.filter(name => definitions[name] || custom[name]).map(name => {
    const definition = definitions[name] ?? custom[name];
    return { type: 'function', function: { name, description: definition.description, parameters: definition.parameters } };
  });
}

export function validateToolArguments(name: string, value: unknown, custom: Record<string, CustomToolSchema> = {}): value is Record<string, unknown> {
  const definition = definitions[name] ?? custom[name];
  if (!definition || !value || typeof value !== 'object' || Array.isArray(value)) return false;
  const args = value as Record<string, unknown>;
  const schema = definition.parameters;
  if (schema.additionalProperties === false && Object.keys(args).some(key => !(key in schema.properties))) return false;
  if ((schema.required ?? []).some(key => !(key in args))) return false;
  for (const [key, argument] of Object.entries(args)) {
    const property = schema.properties[key] as { type?: string; minimum?: number; maximum?: number; minLength?: number; maxLength?: number; enum?: Array<unknown> } | undefined;
    if (!property) return false;
    if (property.type === 'string') {
      if (typeof argument !== 'string' || (property.minLength !== undefined && argument.length < property.minLength) || (property.maxLength !== undefined && argument.length > property.maxLength)) return false;
    } else if (property.type === 'number' || property.type === 'integer') {
      if (typeof argument !== 'number' || !Number.isFinite(argument) || (property.minimum !== undefined && argument < property.minimum) || (property.maximum !== undefined && argument > property.maximum)) return false;
      if (property.type === 'integer' && !Number.isInteger(argument)) return false;
    } else if (property.type === 'boolean') {
      if (typeof argument !== 'boolean') return false;
    } else return false;
    if (property.enum && !property.enum.includes(argument)) return false;
  }
  return true;
}
