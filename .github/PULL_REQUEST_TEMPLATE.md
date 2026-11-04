## What and why

<!-- What does this change, and why is it needed? Link the issue: "Fixes #123". -->

## How it was tested

<!-- Commands you ran and what they showed. New behaviour needs a test in Tools/run_checks.sh
     or a vector in photofinder-selftest. -->

## Checklist

- [ ] `Tools/run_checks.sh` passes.
- [ ] No networking code, network entitlement or new dependency (or it's explained above and discussed first).
- [ ] Nothing is written to the iPhone.
- [ ] No real photos, backups, databases, names or device identifiers in code, tests or screenshots.
- [ ] Nothing claims to recover more than it can; anything labelled deleted is based on evidence.
- [ ] README and a line under **Unreleased** in CHANGELOG.md are updated.
