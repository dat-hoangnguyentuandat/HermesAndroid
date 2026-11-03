# Changelog

## 1.0.1

- Use CPython 3.14 and upgrade incompatible Node.js installations to Node 26.
- Bundle the AArch64 libatomic runtime required by Node 26.
- Install Python dependencies from the upstream frozen uv lockfile and apply
  its dependency overrides, including the Pillow/browser-harness override.
- Build editable Hermes metadata with the bootstrap interpreter so release
  isolation does not hide build dependencies.
- Validate installed Python dependencies using the same upstream overrides.
- Record installer errors and runtime download stages in install.log.

Validation: 11 automated tests passed; installation and reinstallation succeeded
on a rooted RMX3888 with SuKiSU. Hermes CLI and update checks passed, and the
dashboard returned HTTP 200. Model calls require provider credentials and were
not tested.
