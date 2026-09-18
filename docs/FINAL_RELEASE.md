# P2 RV32 DMA/APB SoC：修复版交付说明

## 1. 系统实际做什么

FRISCV RV32IM CPU 运行裸机 C 固件，经上游 AXI4-Lite crossbar 访问 RAM、UART、P2 DMA 和 P2 AXI/APB bridge/timer。固件配置定时器，准备 256 bytes 数据，启动 DMA；DMA 工作时 CPU 继续读取 uncached RAM。随后 CPU 核对全部 64 个 word 和相邻 guard，通过真实 UART TX 输出 `P2_DMA_PASS`。

另一个固件镜像启用 machine external interrupt：CPU 分别处理 timer 和 DMA 中断，读取并核对 `mcause=0x8000000b`，清除中断源，并由 `MRET` 返回。测试台独立检查两类 ISR 各执行一次、IRQ 最终撤销、数据和 UART 结果。

## 2. 来源和修改

| 内容 | 来源 / P2 工作 |
| --- | --- |
| CPU、I/D cache、GPIO/CLINT/UART | [dpretet/friscv](https://github.com/dpretet/friscv)，MIT，固定 `5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba` |
| AXI4-Lite 仲裁、路由和响应互联 | [dpretet/axi-crossbar](https://github.com/dpretet/axi-crossbar)，MIT，固定 `7738a3811623ef4b5610082347bfecce35d95dd2` |
| SoC 顶层、端口/地址/ID 接线 | 新增集成；wrapper 不把上游仲裁算法重新列为原创 |
| DMA、AXI-Lite/APB bridge、APB timer | 新增 IP，有独立参考模型、压力测试及系统固件验证 |
| 七个上游 RTL 补丁 | 定位和修复候选；只应用于构建副本，保留上游原 notice/许可证和固定 Git 子模块 |
| 固件、RAM 模型、测试台、回归与图表脚本 | 新增或改进的验证材料；测试模型与实际硬件分开说明 |

新增 RTL 保留根目录 `CERN-OHL-S-2.0` 许可标识；上游保留各自 MIT 和递归依赖 notice。[SOC_UPSTREAM_LOCK.json](../SOC_UPSTREAM_LOCK.json)列出版本。

构建程序 [prepare_upstream.py](../scripts/prepare_upstream.py)校验 pin 与原版 RTL，按固定顺序生成 `build/p2_upstream_hardened/`。固定 `third_party/friscv` 保持原始内容。

## 4. 复现与验收

```bash
git submodule update --init --recursive
bash scripts/run_release.sh
python3 scripts/record_verification.py --check
```

`run_release.sh` 完整执行 `make verify`，保存真实顶层输出与退出码，再生成源码核验清单。其全部目标是：P2 定向测试、三种 seed 的 IP 压力、crossbar 接线、IO/cache/CPU 故障红绿、9 个系统场景、告警门禁及门禁拒绝测试、固定配置上游回归矩阵。任何异常失败都会停止验收；不会自动删除用例。上游矩阵采用指定 platform 和 Lite/no CDC/pipeline 配置，没有遍历 full AXI、CDC 和所有参数组合。

| 验证集合 | 要求 |
| --- | --- |
| P2 timer | 3 seed × wait 0/1/3；7,605 次 APB 传输，独立逐拍参考模型 |
| P2 DMA | 每 seed 27 个压力 job；16..4096-byte、地址边界、五通道等待/复位、错误响应、IRQ/W1C 碰撞和恢复 |
| P2 bridge | 共 480 对随机读写，加定向 lane/strobe/等待/错误/复位场景 |
| CPU 数据异常 | memfy 39 项检查；cache 开启、pipeline 0/1，60 个完整 CPU 故障与年轻指令场景 |
| CPU 取指/控制异常 | cache 开/关 × 两类响应错误、恢复重取；屏蔽 IRQ 的异常优先级；新增 enabled IRQ/fault 碰撞 48 场景 |
| SoC | 普通 RAM、5 个延迟 seed、DMA 中途复位、2 个真实 CPU ISR 场景；共 9 个 |
| 上游矩阵 | 原版 WBA 11、补丁 WBA 11、RV32I 39、RV32M 8、REPL/CoreMark 2、32/128-bit crossbar 各 9；89 次配置化执行（含重复基线及双宽度），单独统计 |

系统监测 8 个总线接口的五通道 payload/VALID 在背压期间稳定，并跟踪请求和响应。CPU 源写和目的读使用 64-bit 地址位图逐项核对；RAM 内容、guard、foreground CPU 流量及 UART 引脚另行核对。

图表重新生成：在安装 [requirements-figures.txt](../requirements-figures.txt) 的 Python 环境执行 `python scripts/render_evidence.py`。脚本从真实采样 CSV 重新解码 UART，系统场景未全部通过时拒绝生成通过图表。

## 5. 固定硬件合同与限制

总线为 32-bit address、128-bit data、8-bit ID sideband 的上游 AXI-Lite 风格单拍扩展，不支持 AXI4 burst。**标准 AXI4-Lite 规定数据宽度为 32 或 64 bits；本项目的 128-bit 配置不能宣称标准 AXI4-Lite 完整兼容，也不能无适配直接接标准 VIP/IP。**这里保留 upstream module 的 AXI-Lite 名称，具体接口按本项目固定合同验证。[Arm IHI 0022H，B1 AXI4-Lite](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)

三个活动 initiator 是 instruction、data、DMA；第四口 idle。缓存开启，CPU/DMA 共享缓冲 `0x000C0000–0x000C1FFF` 为 uncached。没有 cache coherence 声明。

| 地址 | 目标 |
| --- | --- |
| `0x00000000–0x000FFFFF` | 1 MiB 行为 RAM，保留绝对地址 |
| `0x00100000–0x0010003F` | FRISCV IO/UART，减基址后进入上游接口 |
| `0x00100040–0x0010007F` | P2 DMA control，保留绝对地址 |
| `0x00100080–0x001000BF` | P2 AXI/APB bridge → timer，保留绝对地址 |

DMA 支持非重叠、16-byte 对齐、16..4096-byte 的 RAM 拷贝。reset 压力是整个总线域共同复位，不声称可以仅复位一个 master 来撤销已被未复位 slave 接收的事务。上游自身 `en/wr/ready` 外设接口不是标准 APB；标准 APB 行为由 P2 bridge/timer 提供。只读 instruction 写通道由顶层置空，不依赖上游未实施的 `MST0_RW` 拒写功能。

为保证精确异常，CPU 当前将访存指令序列化；不能沿用原版的访存并行性能主张。CoreMark 只核验算法 CRC，上游时间移植层不支持引用标准 CoreMark/MHz 成绩。10 ns 是仿真时钟设定，不是实测 Fmax。

这是指定源码、工具和配置的仿真交付。未进行 FPGA/ASIC 上板、全系统综合、物理 STA/PPA 或穷尽形式证明。新增或功能性告警不允许静默放行。通过这些测试不能宣称所有可能的输入均无 bug。
