# Contributing to icinga-plugins

Thank you for your interest in contributing!

## Before You Submit

All contributions must follow the standards defined in [CLAUDE.md](CLAUDE.md).

## New Plugin Checklist

- [ ] Plugin script (`.sh` or `.py`) with MIT license header
- [ ] `README.md`
- [ ] `INSTALL.md`
- [ ] `CHANGELOG.md`
- [ ] `icinga2/checkcommand.conf`
- [ ] `icinga2/host_template.conf` (if applicable)
- [ ] `icinga2/service.conf`
- [ ] Passes ShellCheck / ruff with zero errors
- [ ] Root `README.md` plugin index updated
- [ ] Root compatibility matrix updated

## Linting

Bash:
  shellcheck plugins/bash/your_plugin/your_plugin.sh

Python:
  ruff check plugins/python/your_plugin/your_plugin.py

## Pull Requests

- One plugin per PR
- Commit messages: [plugin_name] Short description
- All linting must pass before review

## License

By contributing you agree your code will be released under the MIT License.
