# Self-hosted macOS runner

The `build` and `full-check` jobs in `.github/workflows/ci.yml` run on a macOS arm64 runner registered to this repository. GitHub-hosted jobs can't start while the account's Actions billing is locked, but self-hosted jobs still run.

## Registration

| Field | Value |
|-------|-------|
| Labels | `self-hosted`, `macOS`, `ARM64`, `ovo` |
| Register at | [Settings → Actions → Runners → New self-hosted runner](https://github.com/donaldfilimon/ovo/settings/actions/runners/new?arch=arm64) (macOS, ARM64) |

A runner is registered to one repository. If the same Mac already runs a runner for another repository (for example `abi`), install a second runner in its own directory, such as `~/actions-runner-ovo`, run its `./config.sh` with the token from the page above, add the custom label `ovo` when asked, then run `./svc.sh install && ./svc.sh start`.

Until a runner with these labels is online, same-repo jobs wait in the queue.

## Host requirements

- **Command Line Tools with the macOS 15.4 SDK.** `scripts/zigw` exits unless `/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk` exists (see `scripts/xcrun` for why the Xcode SDK is avoided on macOS 26.4+). To use another CommandLineTools SDK, add `OVO_MACOS_SDKROOT=/path/to/MacOSX<ver>.sdk` to the runner's `.env` file in its directory and restart the service. The Command Line Tools also provide `clang++` and `g++`.
- **Homebrew.** The `full-check` job installs `llvm`, `cmake`, `ninja` and `doxygen` if they are missing (no `sudo`, no auto-update) and puts only `clang-format`, `clang-tidy` and `clang-doc` from the keg-only `llvm` on `PATH`. `scripts/check-cli-test-env.sh` needs all of them. Install them ahead of time with `brew install llvm cmake ninja doxygen` to keep the first run short.
- **Zig** needs no host install. `mlugg/setup-zig` downloads the pinned `0.16.0-dev.2984+cb7d2b056` build from the Zig community mirrors, checks its minisign signature, and keeps it in the runner's tool cache. ziglang.org no longer serves this dev build, and `goto-bus-stop/setup-zig@v2` asks for the pre-0.14.1 file name (`zig-macos-aarch64-…`), so the moved jobs use `mlugg/setup-zig` instead.

## Security

This repository is public, so the self-hosted jobs run only for `push` and for pull requests from branches in this repository (the `if:` also accepts `workflow_dispatch`, which this workflow doesn't declare today). Every self-hosted job also checks `github.repository == 'donaldfilimon/ovo'`, so forks that copy the workflow never target this runner. Fork pull requests use the GitHub-hosted `build-hosted` and `full-check-hosted` jobs instead: never schedule untrusted code on the self-hosted machine.

Checkouts use `persist-credentials: false`, and the workflow token is `contents: read`. Third-party actions on the self-hosted jobs are pinned to a commit SHA.

Where you can, use a dedicated macOS user for the runner rather than your daily account. Keep no production secrets on the host.

## Stays GitHub-hosted

- `build-hosted` and `full-check-hosted`: unchanged copies of the original jobs (Ubuntu and macOS matrix; Ubuntu for `full-check`) that run only for fork pull requests. They stay blocked until the billing lock is cleared.
- The Ubuntu leg of `build` no longer runs for pushes and same-repo pull requests: a macOS machine can't provide it. Linux coverage returns when hosted runners are available again.
