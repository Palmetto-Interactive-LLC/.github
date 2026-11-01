GITLEAKS_VERSION ?= 8.30.1
GITLEAKS ?= $(or $(shell command -v gitleaks),.cache/gitleaks/gitleaks)
.PHONY: ci test secrets
ci: test secrets
test:
	@set -e; for test in scripts/tests/*.sh; do bash "$$test"; done

# Scans the full git history. Downloads a pinned, checksum-verified gitleaks when none is installed.
secrets:
	@if [ ! -x "$(GITLEAKS)" ]; then \
	  set -e; arch=$$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x64/'); os=$$(uname -s | tr A-Z a-z); \
	  art=gitleaks_$(GITLEAKS_VERSION)_$${os}_$${arch}.tar.gz; \
	  base=https://github.com/gitleaks/gitleaks/releases/download/v$(GITLEAKS_VERSION); \
	  mkdir -p .cache/gitleaks; \
	  curl -fsSLo .cache/gitleaks/$$art $$base/$$art; \
	  curl -fsSLo .cache/gitleaks/sums.txt $$base/gitleaks_$(GITLEAKS_VERSION)_checksums.txt; \
	  (cd .cache/gitleaks && grep "  $$art$$" sums.txt | sha256sum -c -); \
	  tar -xzf .cache/gitleaks/$$art -C .cache/gitleaks gitleaks; \
	fi
	$(GITLEAKS) detect --source . --redact --no-banner
