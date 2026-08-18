# FRISCV 同拍写响应缺陷与隔离修复

固定来源：`dpretet/friscv` commit `5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba`，许可证 MIT。`third_party/friscv` 保持原样。此目录的 patch 只改 `rtl/friscv_io_subsystem.sv` 一行状态跳转，原文件开头的 MIT 声明完整保留；这属于针对上游代码的修复候选，不是 P2 自研 IO subsystem。

行为合同：当 `AWVALID` 与 `WVALID` 同时出现，GPIO 写入完成后，IO 从设备须返回一次 `BVALID/BID/BRESP`，且在 `BREADY=0` 时保持响应。测试以 `AWID=0x5a` 向 GPIO 偏移 0 写入 `0x12345678`，检查写入可见、`BID=0x5a`、`BRESP=OKAY`、响应受背压时稳定，接受后不重复。

原版 `IDLE` 分支在同拍 AW/W 时直接进入 `WAIT_BRESP`，但该状态从不等下游 `mst_ready` 或置位 `slv_bvalid`。隔离修复让这条路径进入 `WAIT_WDATA`，复用该状态已有的下游完成和 B 响应逻辑。补丁文件是 [friscv_io_same_cycle_write.patch](friscv_io_same_cycle_write.patch)。

在 WSL Ubuntu 24.04 的项目根目录运行 `bash tb/upstream_friscv/run_same_cycle_write.sh`。脚本先核对 FRISCV SHA，把源码复制到忽略的 `build/upstream_friscv_io/`，只给副本打补丁，再用 Icarus Verilog 12.0 编译同一个 testbench 两次。原版 `vvp` 预期退出码 1，修复版预期退出码 0；脚本整体预期退出码 0。原始日志在 `reports/upstream_friscv/{red,green}-{build,test}.log`，patch 应用记录在 `patch-apply.log`。
