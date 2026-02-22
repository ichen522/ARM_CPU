# Quad HW-Threaded ARM ISA-Compatible Processor on NetFPGA

## 📌 Project Overview
This project features a custom-designed **5-stage pipelined ARM ISA-compatible processor** implemented in Verilog and deployed on the NetFPGA platform. A key architectural highlight is the integration of hardware support for **four simultaneous hardware threads (SMT)**, enabling zero-overhead context switching.

Unlike basic educational processors, this core is heavily optimized to handle complex, compiler-generated ARM assembly (ARMv4T/ARM7TDMI). It features a sophisticated **micro-operation (Micro-op) control engine** for multi-cycle instructions and a hardware-level **Memory Management Unit (MMU)** to ensure safe concurrent execution of C programs, including complex benchmarks like bubble sort.

### Key Objectives
* **Hardware/Software Co-design:** Translating C algorithms into ARM assembly via the `arm-none-eabi` toolchain and ensuring hardware compatibility.
* **Architectural Design:** Developing a custom 5-stage datapath and a highly robust control unit capable of stalling and flushing dynamically.
* **Concurrency:** Implementing a round-robin hardware scheduler for 4-thread interleaving without memory race conditions.
* **Hardware Verification:** Validating execution flow, micro-op state machines, and memory integrity via cycle-accurate simulation.

---

## 🏗️ Processor Architecture
The core utilizes a classic RISC pipeline structure with significant enhancements for multi-threading and CISC-like instruction support.

### 1. The 5-Stage Pipelined Datapath
1. **IF (Instruction Fetch):** Fetches 32-bit instructions from IMEM based on the dynamically selected Thread ID's Program Counter.
2. **ID (Instruction Decode):** Decodes opcodes, handles immediate generation, and reads from the banked Register File.
3. **EX (Execute):** Performs ALU operations, barrel shifting, and precise branch target evaluation (`Target = PC + 8 + offset`).
4. **MEM (Memory Access):** Handles Load/Store operations. Features combinational reads to perfectly align with pipeline timing.
5. **WB (Write Back):** Updates the architectural state in the register file.

### 2. Advanced Control Unit (Micro-op Engine) 🌟
A standout feature of this processor is its highly advanced Control Unit, designed to handle complex ARM block transfer instructions (which are typically nightmares for basic RISC pipelines).
* **LDM/STM State Machine:** Implements a hardware micro-sequencer to break down multi-register Load/Store (`LDMIA`, `STMIA`) into a series of single-cycle micro-operations.
* **Dynamic Pipeline Freezing:** Capable of perfectly stalling the frontend (IF/ID) while the micro-op engine iterates through the 16-bit register mask, pushing or popping data cycle-by-cycle.
* **Base Register Protection:** Employs intelligent register overriding (`override_rg1`, `override_wa`) to cache the Base Register (`Rn`) during multi-cycle execution, preventing data corruption as the pipeline shifts.

### 3. Hardware Multithreading & Memory Banking 🌟
To maximize throughput and isolate execution contexts:
* **Quad-Banked Register Files:** Four completely independent contexts (RF0–RF3), giving each thread its own set of 16 registers (including isolated Stack Pointers `SP`).
* **Zero-Overhead Context Switching:** The hardware scheduler rotates threads automatically. Crucially, the scheduler synchronizes with the Control Unit to **pause rotation** when a thread is executing a multi-cycle micro-op, preventing thread-clashing.
* **Hardware Memory Partitioning (MMU):** The Data Memory is isolated at the hardware level. A 16KB continuous memory is logically partitioned using a custom virtual-to-physical address translation scheme, guaranteeing that concurrent sorting algorithms running on different threads never experience Shared Memory Race Conditions.

---

## 📜 ARM Instruction Encoding (A32)
All instructions are fixed-width 32-bit (ARM Mode).

### 1. Instruction Fields
| Bits | Field | Description |
|:---:|:---:|:---|
| **31–28** | `cond` | Execution condition (e.g., `1110` for AL - Always, `1101` for LE - Less/Equal) |
| **27–0** | `instr` | Instruction-specific payload |

### 2. Data Processing Format
Used for: `ADD`, `SUB`, `MOV`, `CMP`
* **I (Bit 25):** Immediate flag.
* **Opcode (24–21):** Defines the arithmetic/logical operation.
* **Rn (19–16):** First source operand register.
* **Rd (15–12):** Destination register.
* **Operand2 (11–0):** Flexible second operand (Immediate or Shifted Register via internal Barrel Shifter).

---

## 🛠️ Supported ISA Subset

| Category | Instructions |
|:---|:---|
| **Data Processing** | `ADD`, `SUB`, `MOV`, `CMP` |
| **Memory Access** | `LDR`, `STR` |
| **Stack/Block Transfer** | `LDMIA` (Pop), `STMIA` (Push) - *Fully supported via Micro-op State Machine* |
| **Flow Control** | `B`, `BGE`, `BLE`, `BX` |

---

## 💻 Software Workflow & Verification
1. **Compilation:** C source code (e.g., Bubble Sort) is compiled using the `arm-none-eabi-gcc` toolchain.
2. **Assembly & Linking:** Assembly code is analyzed, ensuring proper stack frame generation (`push {fp, lr}`), and converted to hex-encoded machine code.
3. **Simulation:** Extensively verified via Verilog testbenches in ModelSim.
4. **Memory State Validation:** Pre-execution and post-execution memory dumps are compared to verify algorithmic correctness (e.g., confirming the array is perfectly sorted within the thread's specific memory bank).

---

## ⚙️ Technologies Used
* **Languages:** Verilog HDL, C, ARM Assembly
* **Tools:** ARM GNU Toolchain, ModelSim (Simulation & Debugging)
* **Platform:** Targeted for NetFPGA

---

## 📊 Results & Architectural Achievements
The processor design was rigorously tested and validated using cycle-accurate RTL simulations in ModelSim.

### 1. Multi-Cycle LDM/STM Execution
Successfully executed compiler-generated stack frame setup (`push {fp, lr}`) and array loading. The Control Unit accurately stalls the pipeline, iterates through the register mask, and resumes normal execution without ghost states or deadlocks.

### 2. Zero-Overhead Multithreading & Memory Safety
Verified the 4-way round-robin hardware scheduler. Waveform analysis confirms the independent execution of four threads. Memory dumps confirm that despite 4 threads executing Bubble Sort simultaneously, the hardware memory partitioning perfectly isolated the arrays, resulting in 4 independently sorted arrays without race conditions.

### 3. Pipeline Hazard Resolution & Flush
Implemented a robust hardware Pipeline Flush mechanism. The system correctly clears the `IF/ID` and `ID/EX` registers upon detecting a taken branch or initiating a micro-op sequence, preventing phantom instructions from altering the architectural state.
