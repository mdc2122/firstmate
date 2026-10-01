### Behavior test timeouts and retried infra flakes

| Script | Outcome | Detail |
|---|---|---|
| `tests/zz-signal.test.sh` | retried infra flake, passed on retry | signature signal-9, first exit 137, retry exit 0 |
| `tests/zz-lingering.test.sh` | timed out | terminated after its 5s per-script bound |
