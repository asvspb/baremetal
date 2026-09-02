# ==============================================================================
# Makefile — цели тестовой системы deploy-baremetal (TEST-SPEC §8)
#   make setup      — установка зависимостей (bats, pwsh, xmllint)
#   make test-fast  — L0–L3, без root (~30 сек)
#   make test       — fast + L1 (pwsh) + L5 dry-run E2E (нужен root)
#   make test-loop  — L4 на loop-устройствах (нужен root, реальные parted/mkfs!)
#   make test-ps    — только L1 (парсинг ps1)
# ==============================================================================
.PHONY: setup test-fast test test-loop test-ps

setup:
	bash tests/setup.sh

test-fast:
	bash tests/run-all.sh fast

test:
	bash tests/run-all.sh full

test-loop:
	bash tests/run-all.sh loop

test-ps:
	bash tests/run-all.sh ps
