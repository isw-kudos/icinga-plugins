# Changelog: check_itop_unassigned_tickets

## [Unreleased]

## [1.0.0] - 2025-01-01
### Added
- Initial release
- Checks iTop for unassigned tickets via REST/JSON API v1.3
- Supports -H, -u, -p, -w, -c, -C, -t arguments
- Distinct curl error handling: exit 6 (DNS), 7 (connect), 28 (timeout) all exit UNKNOWN
- Ticket details (ref, status, title) included in WARNING/CRITICAL output
- Performance data: unassigned ticket count with warn/crit thresholds

### Changed (from original)
- Ticket detail separator changed from ` | ` to `, ` to avoid Icinga perfdata parsing conflicts
- Output format aligned to project standard: PLUGINNAME STATE - message
