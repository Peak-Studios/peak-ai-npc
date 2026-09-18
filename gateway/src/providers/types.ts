import type { TurnInput, TurnOutput } from '../contracts.js';
export interface TextProvider { readonly name: string; complete(input: TurnInput, signal?: AbortSignal): Promise<TurnOutput>; }
