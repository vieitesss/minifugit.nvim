## About the plugin

This is a Neovim plugin, written in Lua, that provides a lightweight Git status UI inspired by fugitive.nvim.

## Before finishing a change

Run `just check` and `just test`. Both must pass. Commands are listed in `CONTEXT.md`.

## Tests

- Use `plenary.nvim` for creating/managing tests.
- Get information about how to create tests from this URL: https://raw.githubusercontent.com/nvim-lua/plenary.nvim/refs/heads/master/TESTS_README.md
- There should be:
    - Functional tests: only for functions that are part of each module's API. Do NOT create tests for local functions
    - UI tests: check whether windows are created/deleted correctly, ensuring the UI is shown as expected during and after the execution of the plugin.
- Use temporary directories as git repositories for testing, do not use real repositories.

## Releases

- When creating a new release, do not create a new branch, do it from main.
- If you are not in the main branch, ask the user for confirmation.
- A release is a SemVer tag `vX.Y.Z` on a commit in `origin/main` history. Pushing the tag runs `.github/workflows/release.yml`, which validates the tag and writes the release notes from the commits since the previous tag. No version string in the code needs bumping.
- Pick the version from the commits since the last tag:
    - any `feat` bumps minor;
    - only fixes and other types bump patch;
    - a breaking change (`!` or `BREAKING CHANGE`) bumps minor while the version is 0.x, and major from 1.0.
- Tag only when main is clean and pushed, and the Tests workflow passed on that commit (`gh run list --branch main`).
- Release with `git tag vX.Y.Z && git push origin vX.Y.Z`, then confirm with `gh release view vX.Y.Z`.

## Formatting

Use `stylua` for formatting. `just check` verifies it.

---

For coding conventions, structure, and project practices, see `docs/CONVENTIONS.md`.
