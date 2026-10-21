## Summary

<!-- One or two sentences: what this PR changes and why. The PR title must follow Conventional Commits with a scope, for example `feat(strategy): add forgejo-tag detection`. -->

## Related issue

Fixes #<!-- issue number --> <!-- or "N/A" if this PR does not track an issue -->

## Type of change

- [ ] Bug fix
- [ ] New strategy
- [ ] New feature (non-strategy)
- [ ] Documentation
- [ ] CI / tooling
- [ ] Refactor (no behavior change)

## Checklist

- [ ] Commit messages follow Conventional Commits format
- [ ] `shellcheck -x -S warning scripts/*.sh strategies/*.sh` passes locally
- [ ] `shfmt -d -i 2 -ci scripts/*.sh strategies/*.sh` produces no diff
- [ ] `actionlint` passes locally
- [ ] `bats tests/ --recursive` passes
- [ ] New scripts or strategies have BATS tests
- [ ] New strategies are documented in `README.md` and `docs/WORKFLOW.md`
- [ ] GitHub Actions changes pin by commit SHA with a version comment

## Notes for the reviewer

<!-- Trade-offs, deliberate omissions, or areas where you want feedback. If a checklist item does not apply, say why here. -->
