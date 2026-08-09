# TriageXR coach relay

This small Cloudflare Worker keeps the OpenAI API key off Vision Pro. It accepts only a bounded simulation-event payload, requests a strict JSON Schema response, and rejects coaching that cites an event not present in the request.

## Configure and deploy

```sh
npm install
npx wrangler secret put OPENAI_API_KEY
npm run deploy
```

Optionally set `OPENAI_MODEL` as a Worker environment variable. The default is `gpt-5.6-luna`.

After deployment, set the app's `TRIAGEXR_COACH_URL` Xcode build setting to the complete endpoint, for example `https://triagexr-coach-relay.example.workers.dev/coach`. Do not place an OpenAI key in the app target, source code, plist, or repository.

## Verify locally

```sh
npm run check
npm test
```

For a public demo, add an account-level Cloudflare rate-limit rule for `POST /coach`. The Worker logs request identifiers and failures, but never logs the coaching payload or API key.
