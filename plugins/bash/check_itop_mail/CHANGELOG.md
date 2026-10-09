# Changelog: check_itop_mail

## [Unreleased]

## [1.0.0] - 2026-09-25
### Added
- Initial release
- Configuration assertion (CRITICAL): the transport still sends mail off the
  host, and `email_transport_smtp.host` is not a configured capture sink
- Database assertion (WARNING): no `priv_event` send failures in the window,
  with `No recipient` correctly excluded — it means a trigger resolved to
  nobody, which is normal rather than a delivery failure
- `--expect-verify-peer` optionally asserts `email_transport_smtp.verify_peer`,
  reporting an *absent* setting separately because it breaks STARTTLS outright
- Config parsed without PHP, which on a containerised deployment is only
  present inside the application container
- Severity ordered CRITICAL > WARNING > UNKNOWN so an unreachable database
  cannot mask a configuration pointing at a sink
- Each half independently skippable with `--no-config` / `--no-db`
- Credentials via `--defaults-file` or `--password-file` only; no `-p` option
- Performance data: `mail_sink`, `email_failures`
