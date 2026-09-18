import type { TurnInput, TurnOutput } from '../contracts.js';
import type { TextProvider } from './types.js';

export class MockProvider implements TextProvider {
  readonly name = 'mock';
  async complete(input: TurnInput): Promise<TurnOutput> {
    const identity = (input.npc.identity as Record<string, unknown> | undefined)?.name ?? 'The NPC';
    if (input.toolResult) {
      const result = input.toolResult.result as Record<string, unknown> | undefined;
      if (input.toolResult.name === 'create_purchase_quote' && result?.ok === true) {
        return { text: `${identity} says: Your quote is ${result.quantity}x ${result.item} for $${result.total}. Select Confirm purchase to continue.`, usage: { provider: this.name } };
      }
      if (input.toolResult.name === 'police_respond_exit') {
        return { text: `${identity} says: ${result?.ok ? 'Understood officer, stepping out now.' : 'I cannot step out of the vehicle right now.'}`, usage: { provider: this.name } };
      }
      return { text: `${identity} says: I checked. The server returned ${JSON.stringify(input.toolResult.result)}.`, usage: { provider: this.name } };
    }
    const lower = input.input.toLowerCase();
    if (lower.includes('stock') && input.allowedTools.includes('get_shop_stock')) return { text: '', toolCall: { name: 'get_shop_stock', arguments: {} }, usage: { provider: this.name } };
    if (input.allowedTools.includes('police_respond_exit') && (lower.includes('step out') || lower.includes('exit') || lower.includes('get out'))) {
      return { text: '', toolCall: { name: 'police_respond_exit', arguments: { accepted: true } }, usage: { provider: this.name } };
    }
    if (input.allowedTools.includes('create_purchase_quote')) {
      const quantityFirst = lower.match(/\bbuy\s+(\d{1,2})\s+(water(?:\s+bottle)?|sandwich(?:es)?)\b/);
      const itemFirst = lower.match(/\bbuy\s+(water(?:\s+bottle)?|sandwich(?:es)?)\s+(\d{1,2})\b/);
      const requestedItem = quantityFirst?.[2] ?? itemFirst?.[1];
      const item = requestedItem === 'water' || requestedItem === 'water bottle'
        ? 'water_bottle'
        : requestedItem === 'sandwiches'
          ? 'sandwich'
          : requestedItem;
      const quantity = Number(quantityFirst?.[1] ?? itemFirst?.[2]);
      if (item && Number.isInteger(quantity) && quantity >= 1 && quantity <= 20) {
        return { text: '', toolCall: { name: 'create_purchase_quote', arguments: { item, quantity } }, usage: { provider: this.name } };
      }
      if (lower.includes('buy')) return { text: `${identity} says: In mock mode, ask to buy water bottles or sandwiches with a quantity, for example: buy 2 water bottles.`, usage: { provider: this.name } };
    }
    return { text: `${identity} says: I heard you. This gateway is running in mock mode; configure a provider for production dialogue.`, usage: { provider: this.name } };
  }
}
