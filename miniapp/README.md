# MoneyTrack MiniApp

Canonical React/Vite frontend for MoneyTrack.

## Local development

```bash
npm install
npm run dev
```

## Production build

```bash
npm ci
npm run build
```

The client uses the existing n8n API contracts under `api/v1/*` and sends Telegram MiniApp `initData` in the `X-Telegram-Init-Data` header.

No backend, database, workflow, or API contract changes are included in this frontend module.
