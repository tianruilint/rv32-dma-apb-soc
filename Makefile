.PHONY: verify p2-ip-units p2-ip-stress upstream-crossbar io-red-green cache-red-green cpu-fault-red-green soc-system warning-gate-selftest upstream-regression crossbar-monitor-red-green evidence
.NOTPARALLEL:

verify: p2-ip-units p2-ip-stress upstream-crossbar io-red-green cache-red-green cpu-fault-red-green soc-system warning-gate-selftest upstream-regression crossbar-monitor-red-green

p2-ip-units:
	bash scripts/run_soc_units.sh

p2-ip-stress:
	bash scripts/run_ip_stress.sh

upstream-crossbar:
	bash scripts/run_upstream_xbar.sh

io-red-green:
	bash tb/upstream_friscv/run_same_cycle_write.sh

cache-red-green:
	bash tb/upstream_friscv/run_cache_prot_replay.sh
	bash tb/upstream_friscv/run_cache_write_backpressure.sh
	bash tb/upstream_friscv/run_cache_write_response.sh

cpu-fault-red-green:
	bash tb/upstream_friscv/run_core_fetch_fault.sh
	bash tb/upstream_friscv/run_core_data_fault.sh
	bash tb/upstream_friscv/run_control_priority.sh

soc-system:
	bash scripts/run_soc.sh

upstream-regression:
	python3 scripts/run_upstream_regression.py

warning-gate-selftest:
	python3 scripts/test_warning_gate.py

crossbar-monitor-red-green:
	python3 tb/upstream_friscv/run_crossbar_bfm_contract.py

evidence:
	python3 scripts/render_evidence.py
