.PHONY: verify p2-ip-units upstream-crossbar io-red-green soc-system
.NOTPARALLEL:

verify: p2-ip-units upstream-crossbar io-red-green soc-system

p2-ip-units:
	bash scripts/run_soc_units.sh

upstream-crossbar:
	bash scripts/run_upstream_xbar.sh

io-red-green:
	bash tb/upstream_friscv/run_same_cycle_write.sh

soc-system:
	bash scripts/run_soc.sh
