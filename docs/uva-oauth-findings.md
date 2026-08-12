# T6 — UVA OAuth probe (non-blocking)

Date: 2026-08-12. Tenant `b8a81d5c-5169-4b0c-a890-c4ffc7cf0c85` (`law.virginia.edu` /
`lawschool.virginia.edu`), account `ehu@law.virginia.edu`.

The probe below ran read-only. It was later escalated on the user's instruction and its outcome
DID change the repo — see "Resolved" at the end, which supersedes the interim verdict.

## ortie surface

`ortie --help`, verbatim:

```
CLI to manage OAuth 2.0 tokens

Usage: ortie [OPTIONS] [COMMAND]

Commands:
  auth         Get a fresh access token by running the account's OAuth grant
  token        Display and refresh an existing OAuth 2.0 access token
  repl         Start a persistent REPL session for one account
  manuals      Generate manual pages to the given directory
  completions  Generate completion script for the give shell(s) to the given directory
  help         Print this message or the help of the given subcommand(s)
```

ortie has no discovery subcommand: it runs a grant that a config file has already declared
(client id, auth/token URLs, scopes). It therefore cannot answer "will this tenant issue a token"
on its own — the question has to be put to the tenant's own endpoints. That is what follows.

## Device-code initiation, verbatim results

`POST https://login.microsoftonline.com/b8a81d5c-5169-4b0c-a890-c4ffc7cf0c85/oauth2/v2.0/devicecode`
with `client_id` and `scope` form fields. Three public client ids × two scope sets:

| client | client_id | scope set | response |
|---|---|---|---|
| Thunderbird | `9e5f94bc-e8a4-4e73-b8be-63364c29d753` | outlook IMAP/SMTP | `OK user_code=E6VEGTV5R uri=https://login.microsoft.com/device expires_in=900` |
| Thunderbird | `9e5f94bc-e8a4-4e73-b8be-63364c29d753` | graph mail | `OK user_code=BQ5LVSNG8 uri=https://login.microsoft.com/device expires_in=900` |
| Microsoft Office | `d3590ed6-52b3-4102-aeff-aad2292ab01c` | outlook IMAP/SMTP | `OK user_code=BGHTQQY8X uri=https://login.microsoft.com/device expires_in=900` |
| Microsoft Office | `d3590ed6-52b3-4102-aeff-aad2292ab01c` | graph mail | `OK user_code=EXBYKF38G uri=https://login.microsoft.com/device expires_in=900` |
| Azure CLI | `04b07795-8ddb-461a-bbee-02f9e1bf7b46` | outlook IMAP/SMTP | `OK user_code=FED96BSZ3 uri=https://login.microsoft.com/device expires_in=900` |
| Azure CLI | `04b07795-8ddb-461a-bbee-02f9e1bf7b46` | graph mail | `OK user_code=FUTA99F4T uri=https://login.microsoft.com/device expires_in=900` |

Scope sets used:

- outlook IMAP/SMTP — `https://outlook.office.com/IMAP.AccessAsUser.All
  https://outlook.office.com/SMTP.Send offline_access` (identical to the dead
  `~/.config/aerc/oauth/devicecode.py`)
- graph mail — `https://graph.microsoft.com/Mail.ReadWrite
  https://graph.microsoft.com/Mail.Send offline_access`

No `error` was returned for any combination. Every initiation succeeded.

## Verdict (superseded — see "Resolved" below)

**Not determined by initiation. A token is not shown to be obtainable, and is not shown to be
unobtainable.**

The plan assumed initiation alone would be decisive — that the tenant would answer with either a
`user_code` or an `error`. It is not. `/devicecode` is a pre-authentication endpoint: it validates
only that the client id and scope strings are well-formed, and mints a code before any user has
identified themselves. It cannot see who will redeem the code, so it cannot apply Conditional
Access, per-user consent, or the app-consent policy that blocks unapproved third-party clients —
all of which are evaluated at **redemption**, against `/token`. Six `OK`s therefore carry no
information about whether `ehu@law.virginia.edu` can get a token.

The only decisive test is redeeming one code: sign in at `https://login.microsoft.com/device`,
enter the `user_code`, and poll `/token`. The result is one of

- a token plus a `scope` list — obtainable, and the granted scopes say via which API;
- `access_denied` / `AADSTS65005` / `AADSTS50105` / `AADSTS530003` etc. — refused, and the
  `error_description` names the policy that refused it.

That step needs a browser sign-in and grants a real app consent against the work account, so it was
left for the user to authorize rather than run here. The codes above are expired (900 s).

## Bearing on the migration

Two facts worth carrying forward, neither of which this task changed:

1. himalaya v2 is built `+msgraph` — a native Microsoft Graph backend that both reads and sends,
   which would make `owa-bridge` unnecessary for himalaya (aerc would still need it). It requires
   `msgraph.auth.token.command` to yield a token with `aud = https://graph.microsoft.com`.
2. `owa-bridge`'s harvested token cannot serve that purpose. It is the OWA first-party session
   token, `aud = https://outlook.office.com` (`src/owa-token.ts:6`). Graph will reject it.

So the msgraph path is gated on exactly the redemption test above, and nothing else.

---

## Resolved: a token IS obtainable

The probe was escalated past initiation on the user's instruction ("don't use owa-bridge, let's
find a way"). Two further experiments, both run 2026-08-12:

### 1. Harvesting Graph from the OWA session — REFUSED

The signed-in Outlook Web tab's MSAL cache holds exactly one `graph.microsoft.com` access token
(client `9199bf20-a13f-4107-85dc-02114787ef48`). It authenticates —

```
GET https://graph.microsoft.com/v1.0/me            -> 200
GET https://graph.microsoft.com/v1.0/me/messages   -> 403 ErrorAccessDenied
```

— because its scope list contains no `Mail.*` entry at all. So the owa-bridge trick does not
transfer to Graph. Recorded because it is the obvious thing to try next and it does not work.

### 2. Device-code redemption — GRANTED

Client `d3590ed6-52b3-4102-aeff-aad2292ab01c` (Microsoft Office, first-party), scopes
`Mail.ReadWrite`, `Mail.Send`, `offline_access`. Redeemed by signing in as
`vwh7mb@lawschool.virginia.edu` at `https://login.microsoft.com/device`. The tenant returned an
access token **and** a refresh token. Granted scopes include, verbatim:

```
https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send
```

and the token works:

```
GET /me/messages?$top=2   -> 200   (real inbox subjects)
GET /me/mailFolders       -> 200   (Archive, Deleted Items, Drafts, Inbox, …)
```

**So the tenant refuses IMAP/SMTP but not Microsoft Graph.** The long-standing premise that "the
UVA tenant grants no OAuth" was too broad: it is specific to the legacy mail protocols.

### Consequence, now implemented

himalaya's work account was moved off owa-bridge onto the native `msgraph` backend, with `ortie`
holding the refresh token (`~/.config/ortie/config.toml`, token at
`$XDG_STATE_HOME/ortie/msgraph.token`, 0600). owa-bridge still runs — **aerc** speaks IMAP and
still needs it — but nothing in the himalaya/mml path touches it.

One incidental finding worth keeping: himalaya v2's *shared* `message add` is not implemented for
Graph (`Microsoft Graph does not support adding messages`). Work drafts go through
`himalaya msgraph message create -f drafts` instead, which sets `\Draft` itself.
