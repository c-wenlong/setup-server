SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Every services/<name>/ and app/<name>/ directory that ships a mocked suite.
# Discovered rather than listed, so adding a service (the checklist in
# AGENTS.md) needs no edit here.
SERVICES := $(patsubst %/tests/run-tests.sh,%,$(wildcard services/*/tests/run-tests.sh app/*/tests/run-tests.sh))

# Pinned so "green locally" and "green in CI" mean the same thing. The CI job
# installs these exact versions; see .github/workflows/ci.yml.
SHELLCHECK_VERSION := 0.10.0
PY := python3

.PHONY: help test test-live test-python test-scripts lint structure registry shellcheck actionlint

help:
	@echo "setup-server"
	@echo
	@echo "  make test         Run every service's mocked suite (sandboxed, no host changes)"
	@echo "  make test-live    Run every service's --live suite (ONLY on a box where they are deployed)"
	@echo "  make test-python  Run the launcher unit suite under coverage (same command as CI)"
	@echo "  make test-scripts Run the mocked suites for repo tooling under scripts/tests/"
	@echo "  make lint         shellcheck + structure check + actionlint (if installed)"
	@echo "  make structure    Per-service contract check (scripts/check-structure.sh)"
	@echo "  make registry     Check app/web/services.json matches services/*/app.json"
	@echo "  make shellcheck   shellcheck -S warning over every shell file (*.sh and the PATH stubs)"
	@echo "  make actionlint   Lint .github/workflows (skipped with a notice if not installed)"
	@echo
	@echo "  Services: $(words $(SERVICES))"

# ---------------------------------------------------------------- testing
#
# Both test targets keep going after a failure and print a summary table at the
# end, because a broken deploy script in one service says nothing about the
# other nineteen. The recipe is a single shell invocation so the tally survives
# across services; `.SHELLFLAGS` has -e, hence the explicit `|| rc=$$?`.

# $(1) is the label for the summary line, $(2) the flags handed to each suite.
define run_suites
	@failed=""; passed=""; \
	for svc in $(SERVICES); do \
	  printf '\n=== %s (%s) ===\n' "$$svc" "$(1)"; \
	  rc=0; \
	  ( cd "$$svc" && ./tests/run-tests.sh $(2) ) || rc=$$?; \
	  if [ "$$rc" -eq 0 ]; then passed="$$passed $$svc"; \
	  else failed="$$failed $$svc"; fi; \
	done; \
	echo; \
	printf '%-28s %s\n' "SERVICE" "RESULT"; \
	printf '%-28s %s\n' "----------------------------" "------"; \
	for svc in $(SERVICES); do \
	  case " $$failed " in *" $$svc "*) printf '%-28s %s\n' "$$svc" "FAIL" ;; \
	                                 *) printf '%-28s %s\n' "$$svc" "pass" ;; esac; \
	done; \
	echo; \
	n_pass=$$(echo $$passed | wc -w); n_fail=$$(echo $$failed | wc -w); \
	if [ "$$n_fail" -eq 0 ]; then \
	  echo "$(1): all $$n_pass suites passed"; \
	else \
	  echo "$(1): $$n_fail failed, $$n_pass passed ->$$failed"; \
	  exit 1; \
	fi
endef

test:
	$(call run_suites,mocked,)

test-live:
	@echo "test-live runs against the REAL deployment on this machine."
	$(call run_suites,live,--live)

test-python:
	@# Discovery runs from the repo root with the start dir as its own top-level
	@# dir: app/web/tests has no __init__.py, so unittest rejects it as a start
	@# dir otherwise. Running from the root is also what makes .coveragerc's
	@# `source = app/web` resolve, so coverage.xml carries repo-root paths.
	@HOME="$$(mktemp -d)"; export HOME; \
	$(PY) -m coverage run --rcfile=.coveragerc \
	  -m unittest discover -s app/web/tests -t app/web/tests -p 'test_*.py'
	@$(PY) -m coverage report --rcfile=.coveragerc
	@$(PY) -m coverage xml --rcfile=.coveragerc

test-scripts:
	@for t in scripts/tests/test-*.sh; do echo "=== $$t"; ./$$t; done

# ---------------------------------------------------------------- linting

lint: shellcheck structure registry actionlint

shellcheck:
	@command -v shellcheck >/dev/null 2>&1 || { \
	  echo "shellcheck not found. Install it (apt install shellcheck, brew install shellcheck),"; \
	  echo "or grab the pinned $(SHELLCHECK_VERSION) release from"; \
	  echo "  https://github.com/koalaman/shellcheck/releases/tag/v$(SHELLCHECK_VERSION)"; \
	  exit 1; }
	@echo "shellcheck $$(shellcheck --version | sed -n 's/^version: //p') (repo pins $(SHELLCHECK_VERSION))"
	@# Scope is every *.sh plus every file whose first line is a shell shebang.
	@# That second half is what pulls in the ~145 PATH stubs under
	@# */tests/stubs/: the most-executed shell in the repo, and invisible to an
	@# extension-based glob because a stub is named after the command it fakes.
	@# Same scope as the pre-commit hook's `types: [shell]`. Exclusions live in
	@# .shellcheckrc at the repo root, one reason per code.
	@list="$$(mktemp)"; trap 'rm -f "$$list"' EXIT; \
	find . -path ./.git -prune -o -path ./.claude -prune -o -type f -print \
	  | sort \
	  | while IFS= read -r f; do \
	      case "$$f" in *.sh) printf '%s\n' "$$f"; continue ;; esac; \
	      IFS= read -r line < "$$f" 2>/dev/null || continue; \
	      case "$$line" in '#!'*sh|'#!'*sh' '*) printf '%s\n' "$$f" ;; esac; \
	    done > "$$list"; \
	echo "linting $$(wc -l < "$$list") shell files"; \
	xargs shellcheck -S warning < "$$list"; \
	echo "shellcheck: clean"

structure:
	./scripts/check-structure.sh

registry:
	$(PY) scripts/build-registry.py --check

actionlint:
	@# Optional: it only matters to someone editing a workflow, and CI runs a
	@# pinned copy regardless. Skip with a notice rather than failing the lint.
	@if command -v actionlint >/dev/null 2>&1; then \
	  actionlint .github/workflows/*.yml && echo "actionlint: clean"; \
	else \
	  echo "actionlint not installed, skipping (https://github.com/rhysd/actionlint)"; \
	fi
