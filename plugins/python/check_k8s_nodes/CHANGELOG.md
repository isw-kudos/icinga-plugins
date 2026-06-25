# Changelog: check_k8s_nodes

## [Unreleased]

## [1.0.0] - 2026-06-08
### Added
- Initial release
- Checks all nodes (or filtered by `-l`/`--selector`) for the Ready condition
- Flags MemoryPressure, DiskPressure, PIDPressure, NetworkUnavailable as CRITICAL
- WARNs on cordoned (unschedulable) nodes unless `--ignore-cordon` is set
- Returns UNKNOWN when zero nodes are listed (likely RBAC / selector mistake)
- Auth via kubeconfig or API URL + Bearer token
- Performance data: nodes_total, nodes_ready, nodes_warning, nodes_critical
