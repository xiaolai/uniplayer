# Contributing

This repository is a fork of [IINA](https://github.com/iina/iina) maintained for
UniPlayer. Upstream's contribution workflow does not apply here; open issues and
pull requests in this repository instead.

## Before you start

- Check the existing issues and pull requests to avoid duplicate work.
- For a large or user-visible change, describe the design first — what it changes,
  what it costs, and how it will be verified.
- Keep unrelated changes out of the same pull request.

## Workflow

1. Build with the instructions in [README.md](README.md#building).
2. Make the change, then run the checks that cover it. At minimum the app must
   build; for player or interop changes, exercise the affected behaviour in a real
   session rather than only compiling it.
3. Open one pull request per logical change.

## License

By submitting a contribution you agree that it is licensed under GPL-3.0-or-later,
the license of this project.

## Localization

The translations in `uniplayer/*.lproj` come from the upstream project. Do not edit
translations that you did not write; add or change English strings in `Base.lproj`
and `en.lproj`.
