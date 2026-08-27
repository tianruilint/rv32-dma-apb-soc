# 固定配置上游回归矩阵与数据异常修复

运行入口（WSL/Linux，仓库根目录）：

```bash
python3 scripts/run_upstream_regression.py
bash tb/upstream_friscv/run_core_data_fault.sh
```

第一条命令始终建立新的 `build/upstream_regression/<UTC时间>/` 源码副本，原始输出、命令、固定版本、工具版本、补丁 SHA-256 与机器可读结果保存在 `reports/upstream_regression/<UTC时间>/`。它不会改写 `third_party/friscv`。SVUT 缓存放在 `build/deps/svut`，必须是 `d75f9ee5a4adecbb92faa7295e3cfbd111bc4df3`；缓存不存在时从 GitHub 获取固定版本，也可用 `--svut <checkout>` 显式指定并核验。

## 固定测试矩阵

| 集合 | 数量 | 真实配置和验收 |
|---|---:|---|
| 原版 FRISCV WBA machine-mode | 11 | `rv32ui-p-test0..10` 全部；platform、Icarus、cache on、128-bit line |
| 应用最终 P2 RTL 补丁后的 WBA | 11 | 同一集合，不能删失败镜像；含访存、CSR、WFI、M 扩展 |
| 补丁版 RV32I ISA 镜像 | 39 | 全部 `rv32ui-p-*.v`；platform、Icarus、cache on |
| 补丁版 RV32M ISA 镜像 | 8 | 全部 `rv32um-p-*.v`，显式选择，避开原 runner 对带星号 `-f` 判断不展开的问题 |
| REPL 和 CoreMark | 2 | Verilator；真实 UART script 和 CoreMark 自检 CRC；两者均必须由仿真器报告成功 |
| AXI4-Lite crossbar 32-bit 随机场景 | 9 | 32-bit data、32-bit address、8-bit ID、4×4、pipeline on、no CDC；每场景 `MAX_TRAFFIC=1024` |
| crossbar 128-bit 扩展随机配置 | 9 | 同样 9 场景，128-bit data；这是上游 Lite-style 扩展，不宣称标准 AXI4-Lite 的 32/64-bit 宽度合规 |
| 合计 | 89 | 配置化测试执行次数，含重复基线及两种数据宽度；不能算作 89 个 P2 自研功能 |

此矩阵运行上表选定的 platform 和应用配置。crossbar 从上游 14 个配置模板中选取 Lite、no CDC、pipeline on 的一个模板，分别运行 32/128-bit 宽度；没有遍历 full AXI、CDC、其他优先级和全部参数组合。矩阵全部通过不等于全部上游配置均已验证。

所有用例均检查退出码、实际仿真成功计数、错误标记和应用关键输出。`%Fatal`、`%Error`、`FATAL:`、`Assertion failed` 即使伴随 PASS 或退出码 0 也判失败。每次执行保存独立日志；缓存编译输出不会覆盖前一次原始编译记录。调试 trace CSV 与 VCD 默认关闭以控制磁盘量，不关闭功能断言。

脚本从 `scripts/prepare_upstream.py` 读取最终 P2 的 RTL 补丁列表，逐项应用到完整源码副本。另应用原有应用编译/runner 兼容补丁，以及依序应用 `axi_crossbar_bfm_width.patch`、`axi_crossbar_bfm_contract.patch`。每个补丁及哈希进入该次 `metadata.json`。应用的补丁不是上游原版代码，复现报告必须保留这个区别。完整运行生成 8 个结果组，crossbar 每组逐条核对 9 个场景成功输出与最终 9/9 汇总。

### memfy 未处理 RRESP/BRESP 错误

`friscv_memfy_fault.patch` 为读写事务保存请求的 PC、指令和访问地址；SLVERR/DECERR 分别上报 load/store access fault；失败 LOAD 不写寄存器，但仍释放 outstanding 和寄存器占用状态。它还修复 MPU 拒绝读访问仍分配 response 元数据的孤立条目。processing 保守地将内存指令序列化，等待响应再留一拍给 control 的 exception FIFO，避免年轻指令先退休。原 control 的异常 PC 保存由独立 `friscv_fetch_fault.patch` 负责。

`friscv_memfy_fault_tb.sv` 的 39 项检查覆盖读写错误、排队的请求信息、成功读、队列释放与 MPU 拒绝后再访问。`core_data_fault_tb.sv` 运行真实缓存开启的 CPU 程序；上游 core 的 `IO_MAP_NB=0`，因此测试地址虽然是 `0x00100020`，仍实际经过 cacheable 路径。

CPU 测试有 **60 个场景**：processing pipeline=0/1 × load miss / store miss / 预填充后的 store hit × SLVERR / DECERR × 五种年轻指令（ADDI、JAL、EBREAK、FENCE.I、ECALL）。每个场景检查 `mcause=5/7`、故障指令 `mepc`、访问地址 `mtval`、年轻指令无退休；trap handler 同址重读必须得到未受污染的 `0x12345678`。内存写错误完成与缓存更新由 `friscv_cache_write_response.patch` 保证。

CoreMark 这里只作为算法 CRC 功能验证。上游移植层 `time_in_secs` 实际采用毫秒换算，输出中的频率和计分文字不能支持标准 CoreMark/MHz 性能结论；本项目不引用它作性能成绩。
