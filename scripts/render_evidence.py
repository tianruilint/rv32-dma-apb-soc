#!/usr/bin/env python3
"""Render exportable figures from real cycle-sampled simulation CSV and results."""
from pathlib import Path
import csv
import hashlib
import json
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
os.environ.setdefault("MPLCONFIGDIR", str(ROOT / "build/matplotlib-cache"))
if os.name == "nt" and (ROOT / "build/plot-deps").exists():
    sys.path.insert(0, str(ROOT / "build/plot-deps"))
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

OUT = ROOT / "reports/evidence"
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11,
                     "axes.spines.top": False, "axes.spines.right": False,
                     "svg.fonttype": "none", "figure.facecolor": "#f7fafc"})
BLUE, GREEN, ORANGE, INK = "#2368a2", "#18765c", "#b95d13", "#17324d"

def save(fig, name):
    fig.savefig(OUT / f"{name}.png", dpi=160, bbox_inches="tight")
    fig.savefig(OUT / f"{name}.svg", bbox_inches="tight")
    plt.close(fig)

def load_trace(name):
    with (OUT / name).open() as f:
        return [{k: int(v) for k, v in row.items()} for row in csv.DictReader(f)]

def architecture():
    fig, ax = plt.subplots(figsize=(14, 7))
    ax.set(xlim=(0, 14), ylim=(0, 7)); ax.axis("off")
    ax.text(.2, 6.7, "RV32 DMA/APB SoC | source and data path", fontsize=23, weight="bold", color=INK)
    ax.text(.2, 6.23, "Architecture diagram derived from the checked-in top level. Blue = reused upstream; green = this project (integration and IP).", fontsize=10)
    def box(x, y, w, h, title, detail, color):
        ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0.12",linewidth=1.5,edgecolor=color,facecolor="white"))
        ax.text(x+w/2,y+h*.72,title,ha="center",va="center",color=color,weight="bold",fontsize=13)
        ax.text(x+w/2,y+h*.3,detail,ha="center",va="center",fontsize=10,linespacing=1.5)
    def arrow(a,b,label="",color=INK):
        ax.add_patch(FancyArrowPatch(a,b,arrowstyle="-|>",mutation_scale=15,color=color,lw=1.7))
        if label: ax.text((a[0]+b[0])/2,(a[1]+b[1])/2+.12,label,ha="center",fontsize=9,color=color)
    box(.35,4.4,3,1.35,"FRISCV CPU + caches","RV32IM + Zicsr\nInstruction / data masters",BLUE)
    box(.35,1.5,3,1.4,"DMA engine","128-bit single-beat copy\nControl slave + RAM master",GREEN)
    box(4.65,2.0,3.2,3.6,"Upstream AXI-Lite\ncrossbar","dpretet/axi-crossbar\n3 active initiators / 4 targets\nSoC address + ID mapping",BLUE)
    box(9.0,4.8,4.1,.85,"External RAM model","1 MiB behavioral simulation RAM",INK)
    box(9.0,3.5,4.1,.85,"FRISCV IO / UART","GPIO / CLINT / serial TX",BLUE)
    box(9.0,2.2,4.1,.85,"DMA control","SRC / DST / LENGTH / STATUS",GREEN)
    box(9.0,.9,4.1,.85,"APB bridge + timer","128-bit AXI-Lite to 32-bit APB",GREEN)
    arrow((3.47,5.08),(4.5,5.08),"I / D")
    arrow((3.47,2.2),(4.5,2.7),"DMA")
    for y in (5.2,3.9,2.6,1.3):
        arrow((7.98,max(y,2.1)),(8.85,y))
    ax.text(.35,.55,"Firmware: configure timer → fill 256 bytes → start DMA → check all 64 words + guards → UART P2_DMA_PASS",fontsize=11,color=INK)
    ax.text(.35,.1,"128-bit upstream Lite-style extension with ID sidebands; standard AXI4-Lite is 32/64-bit. Simulation, not physical implementation.",fontsize=9,color="#526779")
    save(fig,"architecture")

def digital(ax, rows, channels, title):
    x = [r["cycle"] for r in rows]
    n = len(channels)
    for index, (key, label, color) in enumerate(channels):
        base = (n-index-1)*1.45
        ax.step(x,[base+.85*r[key] for r in rows],where="post",color=color,lw=1.5)
        ax.text(x[0]-.7,base+.42,label,ha="right",va="center",fontsize=10)
    ax.set_yticks([]); ax.set_xlim(x[0],x[-1]); ax.set_ylim(-.3,n*1.45)
    ax.grid(axis="x",alpha=.18); ax.set_xlabel("Observed SoC clock cycle (10 ns per cycle)")
    ax.set_title(title,loc="left",fontsize=15,weight="bold",pad=14)

def waveforms(rows):
    dma = next(r["cycle"] for r in rows if r["ram_arvalid"] and r["ram_arready"] and r["ram_arid"] == 32)
    sample = [r for r in rows if dma-5 <= r["cycle"] <= dma+80]
    fig, ax = plt.subplots(figsize=(14,7.5))
    digital(ax,sample,[("ram_arvalid","ARVALID",BLUE),("ram_arready","ARREADY",BLUE),
        ("ram_rvalid","RVALID",GREEN),("ram_rready","RREADY",GREEN),
        ("ram_awvalid","AWVALID",ORANGE),("ram_awready","AWREADY",ORANGE),
        ("ram_wvalid","WVALID",ORANGE),("ram_wready","WREADY",ORANGE),
        ("ram_bvalid","BVALID",GREEN),("ram_bready","BREADY",GREEN)],
        "Measured DMA traffic | independent RAM stalls, seed 7")
    for r in sample:
        if r["ram_arvalid"] and r["ram_arready"] and r["ram_arid"] == 32:
            ax.axvline(r["cycle"],color=BLUE,alpha=.3,ls="--")
            ax.text(r["cycle"]+.5,14.15,f"DMA read\n0x{r['ram_araddr']:08x}",fontsize=8,color=BLUE)
        if r["ram_awvalid"] and r["ram_awready"] and r["ram_awid"] == 32:
            ax.axvline(r["cycle"],color=ORANGE,alpha=.25,ls="--")
            ax.text(r["cycle"]+.5,6.5,f"DMA write\n0x{r['ram_awaddr']:08x}",fontsize=8,color=ORANGE,
                    bbox={"facecolor":"#f7fafc", "edgecolor":"none", "alpha":.85, "pad":1})
    fig.text(.02,.01,"Source: system-seed7.csv, sampled at every rising clock edge. Bus may also carry CPU transactions; DMA ID = 0x20.",fontsize=9)
    fig.subplots_adjust(left=.15,bottom=.12,top=.9)
    save(fig,"dma-waveform")

    apb = next(r["cycle"] for r in rows if r["apb_psel"] and not r["apb_penable"])
    sample = [r for r in rows if apb-3 <= r["cycle"] <= apb+24]
    fig, ax = plt.subplots(figsize=(14,4.4))
    digital(ax,sample,[("apb_psel","PSEL",BLUE),("apb_penable","PENABLE",BLUE),
        ("apb_pready","PREADY",GREEN),("apb_pwrite","PWRITE",ORANGE)],
        "Measured CPU → AXI-Lite/APB bridge → timer transaction")
    for r in sample:
        if r["apb_psel"] and r["apb_penable"] and r["apb_pready"]:
            ax.axvline(r["cycle"],color=GREEN,ls="--",alpha=.5)
            ax.text(r["cycle"]+.3,5.45,f"Access accepted: 0x{r['apb_paddr']:08x}\n{'write' if r['apb_pwrite'] else 'read'} 0x{r['apb_pwdata'] if r['apb_pwrite'] else r['apb_prdata']:08x}",fontsize=9)
    fig.text(.02,.01,"Source: system-seed7.csv. PSEL precedes PENABLE; transfer completes on PSEL && PENABLE && PREADY.",fontsize=9)
    fig.subplots_adjust(left=.15,bottom=.19,top=.84)
    save(fig,"apb-waveform")

def uart(rows):
    values = [r["uart_tx"] for r in rows]
    frames=[]; i=1
    while i+47 < len(rows):
        if values[i-1] == 1 and values[i] == 0:
            if values[i+2] != 0 or values[i+47] != 1:
                raise RuntimeError(f"UART framing failed near cycle {i}")
            byte = sum(values[i+7+5*b] << b for b in range(8))
            frames.append((rows[i]["cycle"],byte)); i += 49
        else: i+=1
    text="".join(chr(byte) for _,byte in frames)
    if text != "P2_DMA_PASS\n": raise RuntimeError(f"Unexpected UART trace decode: {text!r}")
    fig, ax=plt.subplots(figsize=(14,3.5))
    start=frames[0][0]-5; end=frames[-1][0]+52
    sample=[r for r in rows if start<=r["cycle"]<=end]
    ax.step([r["cycle"] for r in sample],[r["uart_tx"] for r in sample],where="post",color=BLUE)
    for t,b in frames:
        ax.axvspan(t,t+50,alpha=.06,color=BLUE)
        ax.text(t+24,1.22,"\\n" if b==10 else chr(b),ha="center",fontsize=13,color=INK,weight="bold")
    ax.set(xlim=(start,end),ylim=(-.15,1.6),yticks=[0,1],ylabel="UART TX",xlabel="Observed SoC clock cycle")
    ax.set_title("Measured serial output | decoded from sampled TX pin: P2_DMA_PASS\\n",loc="left",weight="bold",pad=16)
    fig.text(.02,.01,"Source: system-seed7.csv. 8 data bits, LSB first, one stop bit, 5 SoC cycles per bit; decoder checks start/stop bits.",fontsize=9)
    fig.subplots_adjust(bottom=.23,top=.82)
    save(fig,"uart-evidence")
    return text

def results():
    scenarios=json.loads((ROOT/"reports/p2_soc/system-stress/summary.json").read_text())
    if not all(r["passed"] for r in scenarios):
        raise RuntimeError("Refuse to publish a passing evidence gallery while system scenarios fail")
    fig,ax=plt.subplots(figsize=(12,5.2))
    names=[r["name"] for r in scenarios]
    cycles=[r["cycles"] for r in scenarios]
    bars=ax.barh(names,cycles,color=GREEN,height=.62)
    ax.invert_yaxis(); ax.bar_label(bars,labels=[f"{c:,} cycles | PASS" for c in cycles],padding=6,fontsize=10)
    ax.set_xlim(0,max(cycles)*1.35); ax.set_xlabel("Cycles to firmware success, UART marker and memory/guard checks")
    ax.set_title("System stress regression | all required scenarios",loc="left",fontsize=16,weight="bold",pad=18)
    ax.grid(axis="x",alpha=.15); ax.set_axisbelow(True)
    fig.text(.02,.01,"Polling and IRQ firmware share the same copy/UART checks. RAM delays change cycle counts; reset includes a complete reboot.",fontsize=9)
    fig.subplots_adjust(left=.2,bottom=.16)
    save(fig,"system-regression")

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    # Check all results before generating any success-labelled charts.
    results()
    rows=load_trace("system-seed7.csv")
    decoded=uart(rows)
    waveforms(rows)
    architecture()
    inputs=[OUT/"system-seed7.csv",ROOT/"reports/p2_soc/system-stress/summary.json",
            ROOT/"rtl/soc/p2_soc_top.sv",ROOT/"rtl/soc/p2_upstream_axil_fabric.sv",
            ROOT/"reports/p2_soc/upstream-manifest.json",Path(__file__).resolve()]
    if (ROOT/"reports/p2_soc/verification-manifest.json").exists():
        inputs.append(ROOT/"reports/p2_soc/verification-manifest.json")
    manifest={"kind":"derived from measured simulation traces; architecture is descriptive",
              "matplotlib":matplotlib.__version__,"uart_decoded":decoded,
              "inputs":[{"path":str(p.relative_to(ROOT)),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()} for p in inputs],
              "outputs":[{"path":str(p.relative_to(ROOT)),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()}
                         for p in sorted(OUT.glob("*")) if p.suffix in (".png", ".svg")]}
    (OUT/"figure-manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print("EVIDENCE_FIGURES_PASS 5 PNG + 5 SVG; UART independently decoded")

if __name__ == "__main__": main()
