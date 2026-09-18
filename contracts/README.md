# Shared contracts

These JSON Schemas define the versioned resource/gateway boundary. The FiveM resource sends an authenticated `TurnInput` and accepts one text response or one allowlisted tool call; the gateway must not be treated as an authority for durable gameplay state.

The schemas are intentionally strict at the top level. Provider-specific metadata belongs in the `context.extensions` object and must be registered and size-limited by the server resource. NPC definitions use provider-neutral voice profile identities; provider-native voice IDs are resolved only by the gateway registry.

`TurnOutput.performance` is the shared, validated performance direction for dialogue, TTS, face, gesture, and gaze. `TurnOutput.audio` contains an expiring opaque URL and utterance identity; it never exposes a provider credential or vendor-native URL. `sessionRevision`, `turnId`, `gatewayNonce`, `actionId`, and `utteranceId` prevent stale asynchronous work from being applied.

Contract version: `0.4.0`. Turn input includes validated `sessionRevision`, `turnId`, `gatewayNonce`, and the legacy top-level `voice` field emitted by Lua. The executable `test:contract-runtime` fixture evaluates the production Lua payload expression and posts it to an isolated gateway.
