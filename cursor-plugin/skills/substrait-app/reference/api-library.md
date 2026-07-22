# The API Library — designing apps against existing APIs

The Substrait portal serves a **design-time catalog** of APIs an app can be built
against. It has two kinds of entries:

- **`internal`** — company APIs registered by platform admins. Each entry carries a
  name, slug, description, tags, a base URL, `auth_notes` (how a human gets access —
  documentation, never credentials) and a full **OpenAPI spec**.
- **`app`** — deployed Substrait apps' endpoint inventories: method/path/description
  for every route the app serves, plus its `https://<slug>.apps.substrait.build`
  base URL. These appear automatically once an app deploys.

## Browsing it

The `/substrait:library` command wraps the plugin's `substrait-library.sh`:

```
substrait-library.sh list [--q TERM] [--tag TAG]   # the whole catalog (JSON)
substrait-library.sh show internal|app SLUG        # one entry + endpoint summary
substrait-library.sh spec SLUG [--out FILE]        # an internal entry's full OpenAPI doc
```

Under the hood these call the portal API (`GET /api/library`,
`GET /api/library/{internal|apps}/{slug}`, `GET /api/library/internal/{slug}/spec`),
authenticated with the **account** personal access token (`sbt_…`) — an app-scoped
deploy token cannot browse the library. Prefer the endpoint summaries; pull a full
spec to a file (`--out`) only when you need request/response detail, and grep it
rather than printing it.

## The design-time contract

The library informs *design*; the platform brokers nothing at runtime:

- The deployed app calls library APIs **directly** over the network, exactly as any
  client would.
- Every consumed API's base URL belongs in a **custom env var** (declared in
  `backend/.env.example`), never hardcoded — the library's `base_url` is the
  production default the user configures at deploy time.
- Credentials come from the entry's `auth_notes` process (ask the owning team, mint a
  key, etc.) and are configured by the user as **secret env vars** on the app's
  Settings page (`# secret` in `.env.example`). Never bake them into code or the zip.
- Other Substrait apps' APIs may sit behind that app's Google SSO proxy; check with
  the app's owner whether a service path is available before designing against it.

## Designing an app from the library

1. `list` the catalog and shortlist entries relevant to what the user wants to build.
2. `show` the shortlisted entries; read `auth_notes` and the endpoint summaries.
3. Agree the design with the user: endpoints consumed, what the app stores in its own
   per-app database vs fetches live, env vars (one base URL + credentials per API),
   and the app's own API/frontend surface.
4. Scaffold and implement per this skill's deploy contract, then link and deploy.
