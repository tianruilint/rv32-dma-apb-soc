# RV32 DMA/APB SoC

GitHub 仓库：[`tianruilint/rv32-dma-apb-soc`](https://github.com/tianruilint/rv32-dma-apb-soc)。这是一个运行裸机固件、支持 DMA 搬运与 APB 外设访问的 RV32IM SoC 仿真工程。

FRISCV CPU/cache/UART + 上游 axi-crossbar，接入 P2 DMA、AXI-Lite/APB bridge 和 timer；运行裸机 C 固件，验证 CPU/DMA 并行访问、复制、定时器、真实中断和 UART 输出。

## 可以检查到的工作

- 七个隔离的上游 RTL 修复补丁：IO 响应、cache PROT/握手/写响应、CPU 总线异常和精确退休。
- P2 IP 独立参考模型与随机等待、reset、error、IRQ/W1C 压力回归。
- 9 个系统场景：256-byte DMA copy、CPU 同时访问 RAM、64 个不同 word 和 guard 核对、传输中复位、实际 CPU ISR、UART 串行解码。

## 来源

| 内容 | 归属 |
| --- | --- |
| CPU、cache、IO/UART | [dpretet/friscv](https://github.com/dpretet/friscv)，固定 `5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba` |
| 仲裁和响应路由互联 | [dpretet/axi-crossbar](https://github.com/dpretet/axi-crossbar)，固定 `7738a3811623ef4b5610082347bfecce35d95dd2` |
| SoC 接线、DMA、bridge、timer、固件、验证和修复补丁 | 新增/修改；具体贡献与修改范围见发布说明 |

上游源码和许可证保留不变。构建时对独立副本应用补丁。

## 获取与复现

```bash
git clone --recurse-submodules https://github.com/tianruilint/rv32-dma-apb-soc.git
cd rv32-dma-apb-soc
```

所需工具版本见[交付说明](docs/FINAL_RELEASE.md#4-复现与验收)。完成环境准备后，`make soc-system` 运行 9 个整机场景；完整发布验收使用下一节的命令。

## 一次完整验收

WSL Ubuntu 24.04 的仓库根目录：

```bash
git submodule update --init --recursive
bash scripts/run_release.sh
python3 scripts/record_verification.py --check
```

第一条运行脚本执行全部 `make verify` 目标，失败立即保留日志并停止，不跳过。结果位于 `reports/p2_soc/final-verify.log`，源文件核验清单在 `reports/p2_soc/verification-manifest.json`。所需工具和单项命令见 [发布说明](docs/FINAL_RELEASE.md)。

在安装 `requirements-figures.txt` 的 Python 环境运行 `python scripts/render_evidence.py` 可重新生成；VCD 和构建缓存位于 ignored `build/`。

## 范围

128-bit 单拍 AXI-Lite 风格上游扩展，带 8-bit ID sideband；不是标准 32/64-bit AXI4-Lite 完整兼容接口。32-bit APB register path；1 MiB 行为 RAM。CPU/DMA 缓冲位于 uncached 区域。为保证精确异常，当前 CPU 访存序列化。没有 full AXI4 burst、cache coherence、FPGA/ASIC 上板或物理时序/PPA 结论。变更必须重新通过门禁。协议依据见[交付说明](docs/FINAL_RELEASE.md)。
