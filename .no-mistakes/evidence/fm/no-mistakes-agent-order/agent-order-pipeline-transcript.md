# Live no-mistakes v1.86.0 pipelines in disposable repo /tmp/nm-agentorder.keZ4/repo (isolated daemon --root /tmp/nm-agentorder.keZ4/nmhome; global config agent: [claude])

## Run A: main carries this change's .no-mistakes.yaml (agent: [pi, claude]), real pi + claude
pi started pid=86625
pi exited pid=86625 status=success

## Run B: same config, agent_path_override points pi at a failing stub
pi started pid=37635
pi exited pid=37635 error=pi exited: exit status 1: stub pi refusing (simulated outage)
agent pi failed (pi exited: exit status 1: stub pi refusing (simulated outage)); falling back to claude
claude started pid=38713
claude exited pid=38713 status=success

## Run C (contrast/guard): main reverted to base commit a5b76329 config (agent: [claude, pi]); branch carries [pi, claude]
claude started pid=82719
claude exited pid=82719 status=success
(pi stub invocations during run C: 0)
