# Project memory

## Reviewed baseline (2026-10-25)

- Public iOS Meta Wearables DAT SDK distribution and samples. Preserve the Swift/API guidance in [AGENTS.md](AGENTS.md); [README](README.md) covers package integration.
- Publication base: `origin/main` release 1.0.1 at `bbae597`, used to create `master`. Original local `main` has unpublished changes; preserve and reconcile them separately. Preserve untracked Xcode workspace files.
- Discover actual Xcode schemes/destinations before testing the affected sample; deterministic MockDeviceKit checks and physical acceptance remain distinct.
- Current rollout is documentation-only; application tests have not been run.

## Handoff contract

Rollout verification: policy-coverage and local-link checks passed across all 13 workspace repositories; `git diff --check` passed. Application testing remains outside this documentation-only change.

After each item record task/owner, branch/worktree, base SHA, changed files, commit/PR, acceptance cases, exact verification commands/results/artifacts, pending external acceptance and next action. Store status in [project plan](PROJECT_PLAN.md); reconcile with Git and remote state on resume.
