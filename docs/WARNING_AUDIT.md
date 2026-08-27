# P2 Verilator 告警审计与门禁

## 精确门禁

`scripts/check_warnings.py` 检查每次强制执行 `--lint-only` 的完整日志，逐条比较 `docs/warning_waivers.json` 中的 **类型、文件、行、列、完整消息与数量**，并检查每个涉及源码的 SHA-256。新增告警、消息变化、源码变化、过时 waiver、未解析的诊断均使它失败；该脚本没有“自动接受当前告警”选项。C++ 增量编译可能无动作，所以 binary build 日志不再用作告警计数依据。

```bash
python3 scripts/check_warnings.py system reports/p2_soc/system-lint.log
python3 scripts/check_warnings.py upstream-crossbar reports/p2_soc/upstream-xbar-lint.log
```

编译保留 `-Wall` 原始诊断，`-Wno-fatal` 仅允许收集完整日志，之后必须经过这个严格门禁。没有全局关闭 `WIDTH`、`UNDRIVEN` 或其它告警类别。`UNDRIVEN`、宽度、锁存、多驱动、组合环、未接输入等功能告警被脚本禁止 waiver，即使有人手工把它们加进 JSON 也会失败。

剩余可解释项目主要是：复用模块为其它参数配置保留的端口/参数、明确关闭的 full AXI4/USER/CDC 字段、未接的 FIFO almost-full/debug 输出、仿真专用初始化与时钟/串行解码过程、上游 generate 的命名样式和零基地址的恒真下界比较。每条具体理由记录在 JSON；这个结论只针对锁定配置和源码，不能推广为其它配置天然正确。

“门禁通过”表示没有未审计的新诊断且没有保留的功能告警，**不表示原始 warning 数量为零，也不表示所有可能的 RTL 行为已经证明无错**。读者应同时查看原始日志与故障注入、随机等待、复位、ISA 和系统回归结果。

## 来源与重现

- `scripts/prepare_upstream.py` 验证 FRISCV `5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba` 和 axi-crossbar `7738a3811623ef4b5610082347bfecce35d95dd2`，对源码副本应用补丁并写出每个文件的源/目标 SHA-256。
- `tb/upstream_friscv/friscv_warning_hardening.patch`：PROT、宽度与禁用输出确定化；保留上游 MIT notice。
- `tb/upstream_friscv/friscv_fetch_fault.patch`：cache/controller 异常传播与原始请求 PC。
- `tb/upstream_friscv/friscv_control_retirement.patch`：直接控制指令 memory 屏障、按指令年龄选择同步异常，以及全局 interrupt enable 检查。
- `bash tb/upstream_friscv/run_cache_prot_replay.sh`：原版失败必须出现 `CACHE_PROT_REPLAY_FAIL`，修复版必须出现 `CACHE_PROT_REPLAY_PASS`；任意其它失败都失败退出。
- `bash tb/upstream_friscv/run_core_fetch_fault.sh`：cache 开/关的原版失败与修复版 SLVERR/DECERR、MRET 重试，原始日志在 `reports/upstream_friscv/core-fetch-*-cache*-*.log`。
- `bash tb/upstream_friscv/run_control_priority.sh`：只有第七补丁前后的隔离副本参与比较；保留全局中断禁用情况下错误/正确 mcause 的对照。
