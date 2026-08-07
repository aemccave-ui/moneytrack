# Deployment notes

This branch is not deployed automatically.

Before deployment:

1. Run `npm ci` in `miniapp/`.
2. Run `npm run lint`.
3. Run `npm run build`.
4. Verify the API base URL.
5. Recover and wire the production handlers for photo, voice, and text quick actions.
6. Perform Telegram MiniApp smoke testing before replacing the current static build.
