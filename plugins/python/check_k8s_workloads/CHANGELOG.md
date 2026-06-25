# Changelog: check_k8s_workloads

## [Unreleased]

## [1.0.0] - 2026-06-08
### Added
- Initial release
- Checks Deployments and StatefulSets cluster-wide or filtered by namespace / label selector
- Detects ready < desired (WARNING), 0 ready (CRITICAL), and stalled Deployment rollouts (ProgressDeadlineExceeded, CRITICAL)
- Detects rollout-in-progress via observedGeneration < generation
- Optional flags to skip Deployments (`--no-deployments`) or StatefulSets (`--no-statefulsets`)
- Auth via kubeconfig or API URL + Bearer token
- Performance data: workloads_total, workloads_ok, workloads_warning, workloads_critical, replicas_desired, replicas_ready
