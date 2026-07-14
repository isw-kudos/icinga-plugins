# Changelog: check_k8s_pods

## [Unreleased]

## [1.1.0] - 2026-07-14
### Added
- `--exclude-restart-pod PATTERN` (repeatable) — skip the restart-count
  thresholds (`-w` / `-c`) for pods whose `namespace/name` matches a shell
  glob. Other pod-health checks (CrashLoopBackOff, ImagePullBackOff,
  Failed, pending-beyond-grace, not-ready) still apply. Suppresses noise
  from pods that restart by design (chaos targets, batch jobs, workloads
  under investigation) without hiding real crash conditions.
- Matched pods are excluded from the `max_restarts` performance-data
  metric so a routinely-restarting pod does not inflate the metric.
- Icinga 2 CheckCommand accepts an array host var
  `check_k8s_pods_exclude_restart_pods` (`repeat_key = true`).

## [1.0.0] - 2026-06-08
### Added
- Initial release
- Lists pods cluster-wide or filtered by namespace (`-n`) / exclude (`--exclude-namespace`) / label selector (`-l`)
- Detects CrashLoopBackOff, ImagePullBackOff, ErrImagePull, InvalidImageName, CreateContainerConfigError, CreateContainerError, RunContainerError, ContainerCannotRun
- Detects Failed / Unknown pod phase and non-zero terminated exit codes
- Pending grace period (`--pending-grace`) before alerting on stuck-Pending pods
- Configurable container restart thresholds (`-w` / `-c`)
- Auth via kubeconfig (`--kubeconfig` + optional `--context`) or API URL + bearer token (`--api-url` / `--token` / `--ca-cert` / `--insecure`)
- SIGALRM-based timeout (`-t`) that interrupts the API list call
- Performance data: pods_total, pods_ok, pods_warning, pods_critical, max_restarts
