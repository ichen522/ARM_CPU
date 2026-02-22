`timescale 1 ns / 100 ps
module pipelinepc(
    input clk,
    input rstb,

    // Software Interface Signals (Control/Programming)
    input  wire [31:0] sw_reset,
    input  wire [31:0] sw_mem_addr,
    input  wire [31:0] sw_mem_wdata,
    input  wire [31:0] sw_mem_cmd,

    // Hardware Status/Output Signals
    output wire [31:0] hw_mem_rdata,
    output wire [31:0] hw_pc,
    output wire [31:0] hw_instr
);

// System reset logic: combines hardware reset with software control
wire sys_rstb = rstb & (sw_reset == 32'd0);

// =====================================================
// Global Wires (Declared to avoid implicit wire errors)
// =====================================================
wire stall_pipeline;
wire cu_start_flush; 
wire actual_branch;

// =====================================================
// Thread Scheduler
// =====================================================
reg [1:0] thread_id_reg;

always @(posedge clk or negedge sys_rstb) begin
    if (!sys_rstb)
        thread_id_reg <= 2'b00;
    else if (!stall_pipeline) // 🌟 CRITICAL: Must freeze rotation during a stall!
        thread_id_reg <= thread_id_reg + 1;   
end

wire [1:0] thread_id = thread_id_reg;

// =====================================================
// PC (Program Counter) Stage
// =====================================================
wire [8:0] current_pc;
wire [8:0] next_pc;
wire [8:0] benq_addr; // Branch target address
wire [1:0] ex_thread_id;

assign next_pc = current_pc + 9'd4;

pc PC (
    .clk(clk), .rstb(sys_rstb), .wen(1'b1),
    .stall(stall_pipeline), .thread_id(thread_id),
    .next_pc(next_pc), .ex_branch(actual_branch),
    .ex_thread_id(ex_thread_id), .ex_branch_target(benq_addr),
    .current_pc(current_pc)
);

assign hw_pc = {23'd0, current_pc};

// =====================================================
// Instruction Memory (IMEM)
// =====================================================
wire [31:0] inst;
// Multiplexer to choose between software programming address and hardware PC
wire [10:0] actual_imem_addr = (!sys_rstb) ? sw_mem_addr[10:0] : {2'b00, current_pc};
wire        actual_imem_wen  = (!sys_rstb) ? (sw_mem_cmd == 32'd1) : 1'b0; 
wire [31:0] actual_imem_wdata = (!sys_rstb) ? sw_mem_wdata : 32'd0;

imem_bram IMEM (
    .clk(clk), .rstb(sys_rstb), .addr(actual_imem_addr),
    .wen(actual_imem_wen), .thread_id(thread_id), .din(actual_imem_wdata), .inst(inst)
);
assign hw_instr = inst;
assign hw_mem_rdata = inst;

// =====================================================
// IF / ID Pipeline Register
// =====================================================
wire [8:0]  id_pc;
wire [31:0] id_instr;
wire [1:0]  id_thread_id;

if_id_reg IF_ID (
    .clk(clk), .rstb(sys_rstb), .en(1'b1),
    .flush(1'b0), .stall(stall_pipeline),
    .if_pc(next_pc), .if_instr(inst), .if_thread_id(thread_id),
    .id_pc(id_pc), .id_instr(id_instr), .id_thread_id(id_thread_id)
);

// =====================================================
// Control Unit & ID Stage MUXes
// =====================================================
wire id_alu_src;
wire [3:0] id_alu_ctrl;
wire [1:0] id_imm_src;
wire id_mem_read;
wire id_mem_write;
wire id_reg_write;
wire id_mem_to_reg;
wire id_branch;
wire [3:0] id_cond;

// Control Unit Override Signals (for LDM/STM micro-operations)
wire [3:0] cu_override_wa; wire use_override_wa;
wire [3:0] cu_override_rg2; wire use_override_rg2;
wire [31:0] cu_override_imm; wire use_override_imm;
wire [3:0] cu_override_rg1; wire use_override_rg1;   

control_unit CU (
    .clk(clk), .rstb(sys_rstb), .flush(actual_branch), .instr(id_instr),
    .alu_src(id_alu_src), .alu_ctrl(id_alu_ctrl), .imm_src(id_imm_src), 
    .mem_read(id_mem_read), .mem_write(id_mem_write), .reg_write(id_reg_write), 
    .mem_to_reg(id_mem_to_reg), .branch(id_branch), .cond(id_cond),
    .stall_pipeline(stall_pipeline), .start_flush(cu_start_flush),
    .override_wa(cu_override_wa), .use_override_wa(use_override_wa),
    .override_rg2(cu_override_rg2), .use_override_rg2(use_override_rg2),
    .override_imm(cu_override_imm), .use_override_imm(use_override_imm),
    .override_rg1(cu_override_rg1), .use_override_rg1(use_override_rg1) 
);

wire [31:0] id_r1data;
wire [31:0] id_r2data;
wire        wb_reg_write;
wire [3:0]  wb_wa;
wire [1:0]  wb_thread_id;
wire        wb_mem_to_reg;
wire [31:0] wb_alu_result;
wire [31:0] wb_read_data;
wire [31:0] wb_wd = wb_mem_to_reg ? wb_read_data : wb_alu_result;

// Resolve register indices with potential overrides from the Control Unit
wire [3:0] real_rg1 = use_override_rg1 ? cu_override_rg1 : id_instr[19:16];
wire [3:0] base_rg2 = (id_mem_write) ? id_instr[15:12] : id_instr[3:0];
wire [3:0] id_rg2   = use_override_rg2 ? cu_override_rg2 : base_rg2;
wire [31:0] raw_r1data;
wire [31:0] raw_r2data;

// Register File instantiation
register_file RF (
    .clk(clk), .rst(sys_rstb), .thread(id_thread_id), 
    .rg1(real_rg1), .rg2(id_rg2), .wen(wb_reg_write), .w_thread(wb_thread_id),
    .wa(wb_wa), .wd(wb_wd), .r1data(raw_r1data), .r2data(raw_r2data)
);

// 🌟 R15 (PC) Bypass Logic
// In the ID stage, id_pc is already (Current_PC + 4). 
// Adding another 4 provides (PC + 8) to comply with the ARM specification.
wire [31:0] pc_plus_8 = {23'd0, id_pc} + 32'd4;

// Multiplexer to return PC+8 if the source register is R15
assign  id_r1data = (real_rg1 == 4'd15) ? pc_plus_8 : raw_r1data;
assign  id_r2data = (id_rg2 == 4'd15)   ? pc_plus_8 : raw_r2data;

wire [3:0] id_wa = use_override_wa ? cu_override_wa : id_instr[15:12];
wire [31:0] real_imm_out; 
wire [31:0] id_imm_out = use_override_imm ? cu_override_imm : real_imm_out;

imm_gen ImmGen (.instr(id_instr), .imm_src(id_imm_src), .imm_out(real_imm_out));

// =====================================================
// ID / EX Pipeline Register
// =====================================================
wire ex_alu_src;
wire [3:0] ex_alu_ctrl;
wire ex_mem_read;
wire ex_mem_write;
wire ex_reg_write;
wire ex_mem_to_reg;
wire ex_branch;
wire [3:0] ex_cond;
wire [8:0] ex_pc;
wire [31:0] ex_instr;
wire [31:0] ex_r1data;
wire [31:0] ex_r2data;
wire [31:0] ex_imm_out;
wire [3:0]  ex_wa;

id_ex_reg ID_EX (
    .clk(clk), .rstb(sys_rstb), .en(1'b1),
    .flush(cu_start_flush), 
    .id_alu_src(id_alu_src), .id_alu_ctrl(id_alu_ctrl), .id_mem_read(id_mem_read),
    .id_mem_write(id_mem_write), .id_reg_write(id_reg_write), .id_mem_to_reg(id_mem_to_reg),
    .id_branch(id_branch), .id_cond(id_cond), .id_pc(id_pc), .id_instr(id_instr),
    .id_r1data(id_r1data), .id_r2data(id_r2data), .id_imm_out(id_imm_out),
    .id_wa(id_wa), .id_thread_id(id_thread_id),
    .ex_alu_src(ex_alu_src), .ex_alu_ctrl(ex_alu_ctrl), .ex_mem_read(ex_mem_read),
    .ex_mem_write(ex_mem_write), .ex_reg_write(ex_reg_write), .ex_mem_to_reg(ex_mem_to_reg),
    .ex_branch(ex_branch), .ex_cond(ex_cond), .ex_pc(ex_pc), .ex_instr(ex_instr),
    .ex_r1data(ex_r1data), .ex_r2data(ex_r2data), .ex_imm_out(ex_imm_out),
    .ex_wa(ex_wa), .ex_thread_id(ex_thread_id)
);

// =====================================================
// EX (Execute) Stage
// =====================================================
wire [31:0] shifted_r2data;
wire [31:0] alu_operand_b;
wire [31:0] ex_alu_result;
wire [3:0]  ex_alu_flags;

barrel_shifter Shifter (.data_in(ex_r2data), .shamt5(ex_instr[11:7]), .sh_type(ex_instr[6:5]), .data_out(shifted_r2data));

// Operand B Mux: Immediate vs Shifted Register
assign alu_operand_b = (ex_alu_src) ? ex_imm_out : shifted_r2data;

alu ALU (.A(ex_r1data), .B(alu_operand_b), .alu_ctrl(ex_alu_ctrl), .result(ex_alu_result), .flags(ex_alu_flags));

wire [3:0] curr_flags;
wire condition_pass;
wire is_data_processing = (ex_instr[27:26] == 2'b00);
wire s_bit = ex_instr[20];
wire update_flags = is_data_processing & s_bit & condition_pass;

// Condition Code Registers (CPSR) per thread
cpsr_array CPSR (
    .clk(clk), .rstb(sys_rstb), .thread_id(ex_thread_id), .update_en(update_flags),
    .alu_flags(ex_alu_flags), .curr_flags(curr_flags)
);

condition_check CondCheck (.cond(ex_cond), .flags(curr_flags), .pass(condition_pass));

// Resolve architectural signals based on condition check
assign actual_branch   = ex_branch    & condition_pass;
wire actual_reg_write  = ex_reg_write & condition_pass;
wire actual_mem_write  = ex_mem_write & condition_pass;

wire is_bx = (ex_instr[27:4] == 24'b000100101111111111110001);

// 🌟 CRITICAL FIX: Ensure PC+4 is accounted for in branch calculation
wire [8:0] b_target_addr = ex_pc + 9'd4 + ex_imm_out[8:0]; 
wire [8:0] branch_target_addr = is_bx ? ex_r2data[8:0] : b_target_addr;
assign benq_addr = branch_target_addr;

// =====================================================
// EX / MEM Pipeline Register
// =====================================================
wire mem_mem_read;
wire mem_mem_write;
wire mem_reg_write;
wire mem_mem_to_reg;
wire [31:0] mem_alu_result;
wire [31:0] mem_write_data;
wire [3:0]  mem_wa;
wire [1:0]  mem_thread_id;

ex_mem_reg EX_MEM (
    .clk(clk), .rstb(sys_rstb),
    .ex_mem_read(ex_mem_read), .ex_mem_write(actual_mem_write), .ex_reg_write(actual_reg_write), .ex_mem_to_reg(ex_mem_to_reg),
    .ex_alu_result(ex_alu_result), .ex_r2data(ex_r2data), .ex_wa(ex_wa), .ex_thread_id(ex_thread_id),
    .mem_mem_read(mem_mem_read), .mem_mem_write(mem_mem_write), .mem_reg_write(mem_reg_write), .mem_mem_to_reg(mem_mem_to_reg),
    .mem_alu_result(mem_alu_result), .mem_write_data(mem_write_data), .mem_wa(mem_wa), .mem_thread_id(mem_thread_id)
);

// =====================================================
// MEM (Memory) Stage
// =====================================================
wire [31:0] mem_read_data;

data_memory DMem (
    .clk(clk),
    .mem_read(mem_mem_read),
    .mem_write(mem_mem_write),
    .addr(mem_alu_result),
    .write_data(mem_write_data),
    .read_data(mem_read_data),
    .thread_id(mem_thread_id)  // 🔥 CRITICAL: Inform memory of the accessing thread
);

// =====================================================
// MEM / WB Pipeline Register
// =====================================================
mem_wb_reg MEM_WB (
    .clk(clk), .rstb(sys_rstb),
    .mem_reg_write(mem_reg_write), .mem_mem_to_reg(mem_mem_to_reg), .mem_alu_result(mem_alu_result),
    .mem_read_data(mem_read_data), .mem_wa(mem_wa), .mem_thread_id(mem_thread_id),
    .wb_reg_write(wb_reg_write), .wb_mem_to_reg(wb_mem_to_reg), .wb_alu_result(wb_alu_result),
    .wb_read_data(wb_read_data), .wb_wa(wb_wa), .wb_thread_id(wb_thread_id)
);

endmodule