# Contributing Guidelines

Contributions are welcome via GitHub Pull Requests. This document outlines the process to help get your contribution accepted.

## How to Contribute

### Technical requirements

### Documentation requirements

### PR approval and release process

#### Versioning (automated)

Chart versions are bumped and published automatically on merge to `main` by
the `release-oci` workflow, so you normally do **not** hand-edit `version:` in
`Chart.yaml`. The bump level is derived from the [Conventional
Commits](https://www.conventionalcommits.org) touching a chart since its last
`<chart>-<semver>` tag:

- `feat:` &rarr; **minor** (case-insensitive; `feature:` and `feat():` do *not* count)
- `fix:`, `chore:`, `docs:`, etc. &rarr; **patch**
- a `<type>!:` subject, or a `BREAKING CHANGE` footer (exactly that, uppercase) &rarr; **major**

If you do bump `version:` manually in your PR, that wins: the workflow respects
it and won't bump again. Each release is tagged `<chart>-<semver>` and pushed to
GHCR as an OCI artifact (`oci://ghcr.io/<owner>/charts/<chart>`).