# Verification results and reproduction

整机场景同时核对 256-byte DMA copy、64 个不同源/目的 word、guard、DMA R/W=16/16、CPU 在 DMA 工作期间的 RAM 流量及真实 UART 输出；ISR 固件核对 timer/DMA 各一次中断、撤销和 MRET 返回。

## 复现

工具：WSL/Linux、Git、Make/patch/coreutils、Python 3、Verilator 5.050、Icarus 12.0、RISC-V GCC 13.2。上游 SVUT 由脚本获取固定版本。

```bash
git submodule update --init --recursive
bash scripts/run_release.sh
python3 scripts/record_verification.py --check
```

`run_release.sh` 完整执行 `make verify` 并保存退出码。异常失败立即停止；不会删除或跳过失败场景。预期 red 测试必须命中特定缺陷，再由同场景修复版通过。新失败需要重新打开相应验收。

只核对当前源码与已归档结果的对应关系时，运行 `python3 scripts/record_verification.py --check`；它核验文件与依赖，不重新执行仿真。

## 固定范围

系统为 128-bit Lite-style 单拍扩展、8-bit ID sideband，不宣称标准 32/64-bit AXI4-Lite 完整兼容或 AXI4 burst。RAM 为 1 MiB 行为模型，DMA 缓冲 uncached，CPU 访存序列化。周期数是仿真验收点，不是 Fmax 或通用吞吐基准。
