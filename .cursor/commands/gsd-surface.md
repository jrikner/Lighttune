<objective>
Manage the runtime skill surface without reinstall. Reads/writes `/workspace/.cursor/.gsd-surface.json`
(sibling to `/workspace/.cursor/.gsd-profile`) and re-stages the active skills directory in place.
Skill dirs live at `/workspace/.cursor/skills/gsd-*/`.

Sub-commands: list · status · profile · disable · enable · reset
</objective>

## Sub-command routing

Parse the first token of {{GSD_ARGS}}:

| Token | Action |
|---|---|
| `list` | Show enabled + disabled clusters and skills |
| `status` | Alias for `list` plus token cost summary |
| `profile <name>` | Write `baseProfile` and re-stage |
| `profile <n1>,<n2>` | Composed profiles (comma-separated, no spaces) |
| `disable <cluster>` | Add cluster to `disabledClusters`, re-stage |
| `enable <cluster>` | Remove cluster from `disabledClusters`, re-stage |
| `reset` | Delete `.gsd-surface.json`, return to install-time profile |
| *(none)* | Treat as `list` |

---

## list / status

Load the capability registry and call `listSurface(runtimeConfigDir, manifest, CLUSTERS, registry)` from
`gsd-core/bin/lib/surface.cjs`. The registry is loaded via:
```js
const registry = require('gsd-core/bin/lib/capability-registry.cjs');
```
Display:

```
Enabled (N skills, ~T tokens):
  core_loop:   new-project  discuss-phase  plan-phase  execute-phase  help  update
  audit_review: …
  …

Disabled:
  utility:  health  stats  settings  …

Token cost: ~T (budget cap ~500 tokens for 200k context @ 1%)
```

For `status` also append:

```
Base profile:   standard  (from .gsd-surface.json)
Install profile: standard  (from .gsd-profile)
```

---

## profile \<name\>

1. Read current surface: `readSurface(runtimeConfigDir)` → if null, seed from `readActiveProfile(runtimeConfigDir)`.
2. Set `surfaceState.baseProfile = name`.
3. `writeSurface(runtimeConfigDir, surfaceState)`.
4. Resolve and re-apply:
   ```js
   const registry = require('gsd-core/bin/lib/capability-registry.cjs');
   const layout = resolveRuntimeArtifactLayout(runtime, runtimeConfigDir, scope);
   applySurface(runtimeConfigDir, layout, manifest, CLUSTERS, registry);
   ```
5. Confirm: "Surface updated to profile `<name>`. N skills enabled."

---

## disable \<cluster\>

Valid cluster names: `core_loop`, `audit_review`, `milestone`, `research_ideate`,
`workspace_state`, `docs`, `ui`, `ai_eval`, `ns_meta`, `utility`.

1. Validate cluster name against `Object.keys(CLUSTERS)`.
2. Read or initialize surface state.
3. Add cluster to `surfaceState.disabledClusters` (deduplicate).
4. `writeSurface` → resolve layout → `applySurface`:
   ```js
   const registry = require('gsd-core/bin/lib/capability-registry.cjs');
   const layout = resolveRuntimeArtifactLayout(runtime, runtimeConfigDir, scope);
   applySurface(runtimeConfigDir, layout, manifest, CLUSTERS, registry);
   ```
5. Confirm: "Disabled cluster `<cluster>`. N skills removed from surface."

---

## enable \<cluster\>

1. Read surface state; if null, nothing to enable — print "No surface delta active."
2. Remove cluster from `surfaceState.disabledClusters`.
3. `writeSurface` → resolve layout → `applySurface`:
   ```js
   const registry = require('gsd-core/bin/lib/capability-registry.cjs');
   const layout = resolveRuntimeArtifactLayout(runtime, runtimeConfigDir, scope);
   applySurface(runtimeConfigDir, layout, manifest, CLUSTERS, registry);
   ```
4. Confirm: "Enabled cluster `<cluster>`. N skills added back to surface."

---

## reset

1. Check if `.gsd-surface.json` exists.
2. Delete it.
3. Re-apply using only `readActiveProfile(runtimeConfigDir)` (install-time profile).
4. Confirm: "Surface reset to install-time profile `<name>`."

---

## runtimeConfigDir resolution

The `runtimeConfigDir` for `applySurface` is the **base Claude config directory**
(`/workspace/.cursor`), NOT the skills sub-directory (`/workspace/.cursor/skills`).

This matches `installRuntimeArtifacts` and `uninstallRuntimeArtifacts`, which also
receive `/workspace/.cursor` as `configDir`. The skill dirs themselves live at
`/workspace/.cursor/skills/gsd-*/` because the `claude global` layout has `destSubpath =
'skills'` — they are derived from `configDir`, not the root for it.

```bash
# Cursor — global install
RUNTIME_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/workspace/.cursor}"
SCOPE="global"

# Artifact destinations are derived from runtime layout
# via resolveRuntimeArtifactLayout(runtime, RUNTIME_CONFIG_DIR, SCOPE)
# then applySurface(RUNTIME_CONFIG_DIR, layout, manifest, CLUSTERS)
```

Surface state is stored at `${RUNTIME_CONFIG_DIR}/.gsd-surface.json`
(i.e. `/workspace/.cursor/.gsd-surface.json`).

All paths can be overridden by reading the `CLAUDE_CONFIG_DIR` env var if set.

---

## Error handling

- Unknown cluster name → list valid cluster names, exit without writing.
- Unknown profile name → list known profiles (`core`, `standard`, `full`), exit.
- Missing `surface.cjs` → prompt: "Run `npm i -g gsd-core` to reinstall GSD."

<execution_context>
Surface state file: `/workspace/.cursor/.gsd-surface.json`
Install profile marker: `/workspace/.cursor/.gsd-profile`
Skill dirs: `/workspace/.cursor/skills/gsd-*/`
Engine module: `/workspace/.cursor/gsd-core/bin/lib/surface.cjs`
Cluster definitions: `/workspace/.cursor/gsd-core/bin/lib/clusters.cjs`
</execution_context>
