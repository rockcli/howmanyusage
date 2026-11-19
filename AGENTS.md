# Project Agent Instructions

## Local app delivery

- After completing any requested source, configuration, or UI change and passing the relevant verification, default to running `./scripts/install.sh`. This builds the release app, installs it to `/Applications/HowManyUsage.app`, reloads the `com.local.howmanyusage` LaunchAgent, and verifies that the installed process is running.
- Skip installation/restart only when the user explicitly asks not to restart, requests a read-only inspection or plan, or the change is blocked before a safe build. Report the exact reason when it is skipped or fails.
