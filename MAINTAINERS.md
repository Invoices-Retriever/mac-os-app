# Maintainers

| Area | Maintainer |
| --- | --- |
| Application, engine, plugin format | @cldt-fr |
| Security reports | @cldt-fr |

Security contact: open a private vulnerability report on this repository.

## What a maintainer commits to

- Triaging new issues within a week.
- Reviewing every pull request that touches a plugin, personally, rather than
  letting CI merge it — this is a security control, not a formality (threat M2).
- Never merging a plugin containing `runJs` without reading the JavaScript.
- Keeping the plugin index signing key out of the repository and out of any
  contributor's hands.

## Becoming one

The path is unglamorous and it works: contribute plugins, help review other
people's, and answer issues. After a few months of that, ask. Maintainers of the
plugins repository do not need to write Swift.

## The signing key

The Ed25519 private key that signs the plugin index lives in a GitHub Actions
secret on the plugins repository and in one offline backup. Its public half is
compiled into the application, so rotating it requires an application release —
do not rotate it casually, and never publish an index signed with anything else.
