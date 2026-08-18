# P2：开源复用的 RV32 AXI4-Lite SoC

## 当前判断

活动版本是一个能运行指定固件与验证场景的 RV32 SoC 仿真项目。它复用固定 [FRISCV](https://github.com/dpretet/friscv) CPU/cache/UART 和其 [axi-crossbar](https://github.com/dpretet/axi-crossbar) 的 AXI4-Lite 互联；新增 SoC 接线、DMA、AXI4-Lite/APB bridge、timer、固件和验证。CPU 与 crossbar 是上游作者的工作，不能列为个人原创。

## 来源和保留内容

| 内容 | 身份 | 当前用途 |
| --- | --- | --- |
| `third_party/friscv/` | 上游固定 commit `5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba`，其 crossbar 依赖固定 `7738a3811623ef4b5610082347bfecce35d95dd2` | CPU/cache/IO/UART 与互联算法；保留各自许可证 |
| `rtl/soc/p2_upstream_axil_fabric.sv`、`rtl/soc/p2_soc_top.sv` | 新增集成 | crossbar 端口映射、地址/ID 配置和 SoC 接线 |
| `rtl/soc/p2_dma.sv`、`rtl/soc/p2_axil_apb_bridge.sv`、`rtl/p2_apb_timer.sv` | 新增 IP | 有定向测试与固件系统场景；不是上游 IP |
| `firmware/soc/`、`tb/`、`scripts/` | 新增固件与测试 | 区分 P2 集成测试和上游原版测试 |

## 复现活动版本

在 WSL Ubuntu 24.04 的仓库根目录运行：

```bash
git submodule update --init --recursive
make verify
```

`make verify` 依次运行 P2 bridge/DMA 单元测试、复用 crossbar 的 P2 接线测试、FRISCV IO 原版失败与隔离修复测试、完整固件系统仿真。需要 WSL Ubuntu 24.04、Git、GNU Make、`patch`、Python 3、GNU coreutils（含 `timeout`/`sha256sum`）、Verilator 5.050、Icarus Verilog 12.0 和 RISC-V GNU 工具链。`build/` 是可清理、可由该命令重新生成的编译缓存；原始日志在 `reports/p2_soc/` 和 `reports/upstream_friscv/`。

总线是 128-bit 数据、8-bit ID sideband 的单拍 AXI4-Lite，RAM 为 1 MiB 仿真模型。FRISCV IO 同拍写漏 B 响应的修复仅应用于构建副本；固定上游源码未改。
