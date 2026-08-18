# P2 RV32 AXI4-Lite SoC：仿真代码交付与证据

## 运行路径与来源

`firmware/soc/main.c` 在 FRISCV RV32 CPU 上运行：先经 AXI4-Lite/APB bridge 配置并轮询 timer，再初始化 256-byte 源/目的缓冲，启动 DMA，逐一核对 64 个 32-bit word 和相邻 guard，最后在 UART TX 引脚输出 `P2_DMA_PASS`，并写入内存成功字。测试台读取真实 UART 串行引脚、终端字、timer 及 RAM/DMA 握手；500,000-cycle 超时仅是失败保护。

| 模块或材料 | 来源与责任 | 活动源码 |
| --- | --- | --- |
| RV32 CPU、I/D cache、IO/GPIO/CLINT、UART | [dpretet/friscv](https://github.com/dpretet/friscv)，MIT，固定 `5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba`；这些不是 P2 原创 | `third_party/friscv/rtl/` |
| AXI4-Lite crossbar 的仲裁、路由、响应与 DECERR | FRISCV 递归依赖 [dpretet/axi-crossbar](https://github.com/dpretet/axi-crossbar)，MIT，固定 `7738a3811623ef4b5610082347bfecce35d95dd2`；不是 P2 原创 | `third_party/friscv/dep/axi-crossbar/rtl/` |
| FRISCV IO 同拍写修复 | 提交的一行**上游缺陷修复候选**；只对构建副本应用，原子模块仍属上游 | `tb/upstream_friscv/friscv_io_same_cycle_write.patch`、`scripts/run_soc.sh` |
| 四源四目标 crossbar 接线、地址窗口、ID mask、SoC 顶层 | 新增集成 RTL；wrapper 不实现仲裁算法 | `rtl/soc/p2_upstream_axil_fabric.sv`、`rtl/soc/p2_soc_top.sv`、`rtl/soc/p2_axil_if.sv` |
| 128-bit 单拍 DMA、128-bit AXI4-Lite→32-bit APB bridge、APB timer | 新增 RTL；有定向测试 | `rtl/soc/p2_dma.sv`、`rtl/soc/p2_axil_apb_bridge.sv`、`rtl/p2_apb_timer.sv` |
| 固件、仿真 RAM、测试台与运行脚本 | 新增验证/演示材料；RAM 为行为模型 | `firmware/soc/`、`tb/soc_*.sv`、`scripts/` |

上游许可和 notice 保留在各 submodule；本仓库新增 RTL 文件标注 `CERN-OHL-S-2.0`，根目录有 `LICENSE`。递归依赖 SHA 见 [source lock](../SOC_UPSTREAM_LOCK.json)。FRISCV 自身的 `en/wr/ready` 外设通路并非标准 APB；上表的 APB 功能由单独的 P2 bridge/timer 提供。

本轮优先复用了 CPU/cache/UART 和承担仲裁/响应路由的上游 crossbar。DMA、bridge、timer 保留为 新增模块，是因为它们已有明确的单元测试与整机测试路径；本轮没有验证某个开源替代 IP 可直接适配这套 128-bit、8-bit ID、地址图与固件合同，故不把这三块伪称为开源模块。

## 硬件边界

外部总线为 32-bit address、128-bit data、8-bit ID sideband 的**单拍 AXI4-Lite**。它不支持 full AXI4 burst。FRISCV cache 开启，`0x000C0000–0x000C1FFF` 设置为数据侧 uncached，以便 CPU 与 DMA 共享缓冲。四个 crossbar 源口依次为 CPU instruction、CPU data、DMA、idle；CPU instruction 的写通道在顶层固定为空，DMA 仅可访问 RAM。第四源口供上游四源配置占位。上游 `MST0_RW` 参数在所用 RTL 中未实施硬件拒写，因此不能以该参数宣称 instruction 源的 RAM 写会被 crossbar 阻止；本系统靠顶层写通道置空。

| 地址范围 | 目标与地址处理 |
| --- | --- |
| `0x00000000–0x000FFFFF` | 外部 1 MiB RAM；仿真接行为模型，目标看到绝对地址 |
| `0x00100000–0x0010003F` | FRISCV IO/UART；crossbar 减去 `0x00100000` 后送目标 |
| `0x00100040–0x0010007F` | P2 DMA control；保留绝对地址 |
| `0x00100080–0x001000BF` | P2 bridge → APB timer；保留绝对地址 |

DMA 以 16-byte beat 顺序读后写；本固件使用 `SRC=0x000C0000`、`DST=0x000C1000`、`LEN=256`。bridge 选择 128-bit 总线中的对应 32-bit lane，驱动 APB Setup/Access 和 `PREADY/PSLVERR`。定向测试涉及 AW/W 分开抵达、背压、错误响应、reset 等，不能据此推断所有未测并发或缓存情形。

## 复现入口与现有证据

在 WSL Ubuntu 24.04 的仓库根目录准备 Git、GNU Make、`patch`、Python 3、GNU coreutils（含 `timeout`/`sha256sum`）、Verilator 5.050、Icarus Verilog 12.0 和 RISC-V GNU 工具链后：

```bash
git submodule update --init --recursive
make verify
```
