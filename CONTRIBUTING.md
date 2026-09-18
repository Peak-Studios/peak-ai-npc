# Contributing to Peak AI NPC

Thank you for your interest in contributing! Here's how to get involved.

## Ways to contribute

- **Bug reports** — Open an issue with steps to reproduce, your framework/inventory/target versions, and redacted `ainpc_status` output.
- **Feature requests** — Open an issue describing the use case and expected behaviour.
- **Pull requests** — Fix a bug, add a feature, or improve documentation.

## Development setup

### Gateway

```powershell
cd gateway
npm ci
npm run dev   # runs with tsx hot-reload
```

Copy `.env.example` to `gateway/.env` and configure at least one text provider.
Set `AI_NPC_PROVIDER=mock` to run without any API keys — the mock provider returns plausible stub responses.

### FiveM resource

The `peak-ai-npc/` folder is a standard FiveM resource. Drop it into any server's `resources/` directory alongside the running gateway.

## Code guidelines

- Keep the Lua/server boundary strict — client events, screenshots, and transcripts are **untrusted**.
- Provider credentials must **never** appear in Lua files, NUI, logs, or events.
- Every new NPC tool must be NPC-allowlisted, gateway-schema-validated, server-registered, and bounded.
- Text/subtitle fallback must always work even when TTS, STT, microphone, or vision fails.
- Run `npm run typecheck` in `gateway/` before submitting a PR.

## Pull request process

1. Fork the repo and create a branch from `main`.
2. Make your changes.
3. Run `npm run typecheck` in `gateway/` — zero errors required.
4. Open a PR with a clear description of what changed and why.

## Reporting security issues

Please **do not** open a public issue for security vulnerabilities. Email us privately instead (link your GitHub profile in the message so we can verify intent).

## License

By contributing you agree that your contributions will be licensed under the [MIT License](LICENSE).
