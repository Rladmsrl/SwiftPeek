# Repository privacy and submission rules

- Keep personal Apple IDs, private email addresses, signing team IDs, certificate
  identities, device names/identifiers/serial numbers, provisioning profiles,
  credentials, cookies, and signed playback URLs out of commits and public output.
  Preserve existing upstream attribution and public project contact information.
- Put local signing settings, device exports, diagnostic reports, and other private
  files in the ignored `.local/` directory. Use `*.local.xcconfig` for local Xcode
  overrides. Never put personal signing values in `project.yml` or tracked sources.
- Xcode projects/workspaces are generated and ignored. Do not force-add ignored
  files or publish the original private repository's history.
- `.gitignore` does not protect tracked file contents. Before every commit or push,
  inspect the staged diff for private data and unintended Xcode configuration edits.
  Scan staged files with a secret scanner when available; never print matching
  secret values. Keep the Git author email set to a GitHub noreply address for
  this checkout, and do not change global Git identity settings.
- Keep application `Info.plist` files tracked: they contain shared runtime
  configuration. Xcode may move keys into the ignored generated project; do not
  commit such removals unless the equivalent shared configuration is preserved.
  Do not discard unrelated local changes or hide them with `assume-unchanged` or
  `skip-worktree`.
