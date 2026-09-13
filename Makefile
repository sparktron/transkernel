.PHONY: test audit validate prepare-kernel

test:
	./tests/run.sh

audit:
	./scripts/audit-host.sh

validate:
	./scripts/validate-system.sh

prepare-kernel:
	./scripts/build-kernel.sh --prepare-only

