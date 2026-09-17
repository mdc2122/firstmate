# Live validation: pi model-discovery contract (pi 0.85.1)

Environment: isolated config via `PI_CODING_AGENT_DIR=/tmp/piconf-evidence` containing
models.json with two custom providers — `ev-authed-provider` (apiKey: $CLIPROXY_KEY,
present in env) and `ev-noauth-provider` (no apiKey) — and settings.json whose
`enabledModels` holds the stale pin `muse-code/muse-spark-1.3` (the exact id from the
reported failures) plus the authed models.

## Scenario A: --list-models hides providers with no configured auth

```
$ pi --list-models ev-noauth
Warning: No models match pattern "muse-code/muse-spark-1.3"
No models matching "ev-noauth"

$ pi --list-models ev-authed
Warning: No models match pattern "muse-code/muse-spark-1.3"
provider            model            context  max-out  thinking  images
ev-authed-provider  ev-authed-model  32K      256      no        no

$ pi --list-models   # full listing provider column
deepseek
ev-authed-provider
```

`ev-noauth-provider` is registered in models.json yet absent from every listing;
an empty listing is therefore not proof a model is unresolvable.

## Scenario B: a hidden (unauthenticated) model still resolves via --model and fails only at the auth check

```
$ pi --model ev-noauth-provider/ev-noauth-model -p "Reply with exactly OK"
Warning: No models match pattern "muse-code/muse-spark-1.3"
No API key found for ev-noauth-provider.

Use /login to log into a provider via OAuth or API key. See:
  /opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/docs/providers.md
  /opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/docs/models.md

$ pi --model muse-code/muse-spark-1.3 -p "hi"   # negative control: truly unknown model
Warning: No models match pattern "muse-code/muse-spark-1.3"
Error: Model "muse-code/muse-spark-1.3" not found. Use --list-models to see available models.
(exit=1)
```

The hidden model does not hit the "not found" launch error; it resolves and dies at
the auth check. The truly-unknown model fails earlier with the fatal Error.

## Scenario C: the stale-pin warning does not fail the launch (intent signature reproduced)

settings.json `enabledModels` contains the stale pin `muse-code/muse-spark-1.3`.

```
$ pi --model zai-glm53-cliproxy/zai-glm53-max -p "Reply with exactly OK and nothing else"
OK
(exit=0)
--- stderr ---
Warning: No models match pattern "muse-code/muse-spark-1.3"
```

The warning is emitted on stderr and the run completes successfully (exit 0), proving
the warning names a non-fatal stale `enabledModels` pin rather than a dead launch.

## dispatch-auth.md example still behaves as documented

```
$ pi --list-models gpt-9.9-nonexistent
No models matching "gpt-9.9-nonexistent"
```

Both corrected documents' claims hold on the real pi 0.85.1 binary.
