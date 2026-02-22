`timescale 1 ns / 100 ps

// ==========================================
// 1. Program Counter (PC)
// ==========================================
module pc(clk, rstb, wen, stall, thread_id, next_pc, ex_branch, ex_thread_id, ex_branch_target, current_pc);
    input clk, rstb, wen, ex_branch;
    input stall; 
    input [1:0] thread_id, ex_thread_id;
    input [8:0] next_pc, ex_branch_target;
    output reg [8:0] current_pc;

    // Separate PC registers for each of the 4 threads
    reg [8:0] pc_reg_0, pc_reg_1, pc_reg_2, pc_reg_3;

    // Read logic: select PC based on current thread_id
    always @(*) begin
        case (thread_id)
            2'b00: current_pc = pc_reg_0;
            2'b01: current_pc = pc_reg_1;
            2'b10: current_pc = pc_reg_2;
            2'b11: current_pc = pc_reg_3;
            default: current_pc = 9'b0;
        endcase
    end

    // Write logic: update PC on clock edge
    always @(posedge clk or negedge rstb) begin
        if (!rstb) begin
            pc_reg_0 <= 9'b0;
            pc_reg_1 <= 9'b0;
            pc_reg_2 <= 9'b0;
            pc_reg_3 <= 9'b0;
        end 
        else begin
            // Normal PC increment/update
            if (wen && !stall) begin
                case (thread_id)
                    2'b00: pc_reg_0 <= next_pc;
                    2'b01: pc_reg_1 <= next_pc;
                    2'b10: pc_reg_2 <= next_pc;
                    2'b11: pc_reg_3 <= next_pc;
                endcase
            end

            // Branching logic: overrides normal update if branch is taken in EX stage
            if (ex_branch) begin
                case (ex_thread_id)
                    2'b00: pc_reg_0 <= ex_branch_target;
                    2'b01: pc_reg_1 <= ex_branch_target;
                    2'b10: pc_reg_2 <= ex_branch_target;
                    2'b11: pc_reg_3 <= ex_branch_target;
                endcase
            end
        end
    end
endmodule

// ==========================================
// 2. Instruction Memory (IMEM)
// ==========================================
module imem_bram (clk, addr, thread_id, wen, din, inst, rstb);
    input  wire        clk;
    input  wire [10:0] addr;
    input  wire        rstb;
    input  wire        wen;       
    input  wire [31:0] din;       
    output reg  [31:0] inst;
    input  wire [1:0]  thread_id;
    reg [31:0] ram_array [0:511];

    integer i; 
    initial begin
        // Initialize and load instructions for Thread 0
        $readmemh("inst.mem", ram_array, 0, 127); 
        
        // Critical: Copy code segment to the other 3 threads
        for (i = 0; i < 128; i = i + 1) begin
            ram_array[i + 128] = ram_array[i]; // Thread 1
            ram_array[i + 256] = ram_array[i]; // Thread 2
            ram_array[i + 384] = ram_array[i]; // Thread 3
        end
    end

    // Map thread-specific address to the physical RAM array
    wire [8:0] real_addr = (!rstb) ? addr[10:2] : {thread_id, addr[8:2]};
    
    // Correction 1: Keep write operations synchronous (Clock Edge)
    always @(posedge clk) begin
        if (wen) begin
            ram_array[real_addr] <= din;
        end
    end

    // Critical Correction 2: Change read logic to combinational for pipeline timing!
    always @(*) begin
        inst = ram_array[real_addr];
    end
endmodule

// ==========================================
// 3. IF / ID Pipeline Register
// ==========================================
module if_id_reg (clk, rstb, en, flush, stall, if_pc, if_instr, if_thread_id, id_pc, id_instr, id_thread_id);
    input  wire        clk;
    input  wire        rstb;
    input  wire        en;  
    input  wire        flush;  
    input  wire        stall; 

    input  wire [8:0]  if_pc;         
    input  wire [31:0] if_instr;      
    input  wire [1:0]  if_thread_id;  

    output reg  [8:0]  id_pc;
    output reg  [31:0] id_instr;
    output reg  [1:0]  id_thread_id;

    localparam ARM_NOP = 32'hE1A00000;

    always @(posedge clk or negedge rstb) begin
        if (!rstb) begin
            id_pc        <= 9'b0;
            id_instr     <= ARM_NOP; 
            id_thread_id <= 2'b0;
        end 
        else if (flush) begin
            id_pc        <= 9'b0;
            id_instr     <= ARM_NOP;
            id_thread_id <= 2'b0; 
        end 
        else if (en && !stall) begin
            id_pc        <= if_pc;
            id_instr     <= if_instr;
            id_thread_id <= if_thread_id;
        end
    end
endmodule

// ==========================================
// 4. Control Unit 
// ==========================================
module control_unit (
    input  wire        clk,
    input  wire        rstb,
    input  wire        flush,         
    input  wire [31:0] instr,

    output reg         alu_src,
    output reg  [3:0]  alu_ctrl,
    output reg  [1:0]  imm_src,
    output reg         mem_read,
    output reg         mem_write,
    output reg         reg_write,
    output reg         mem_to_reg,
    output reg         branch,
    output reg  [3:0]  cond,
    
    output wire        stall_pipeline,  
    output wire        start_flush,     
    output reg  [3:0]  override_wa,     
    output reg         use_override_wa, 
    output reg  [3:0]  override_rg2,    
    output reg         use_override_rg2,
    output reg  [31:0] override_imm,    
    output reg         use_override_imm,
    output reg  [3:0]  override_rg1,      
    output reg         use_override_rg1   
);

    // ARM Instruction Fields
    wire [3:0] cond_field = instr[31:28];
    wire [2:0] op_high    = instr[27:25];  
    wire [1:0] op_mid     = instr[27:26];  
    wire       I_bit      = instr[25];    
    wire [3:0] opcode     = instr[24:21];  
    wire       L_bit      = instr[20];    
    wire       U_bit      = instr[23];    
    wire       link_bit   = instr[24];    

    wire is_block_transfer = (op_high == 3'b100);
    
    // Logic to detect the start of a multi-register transfer (LDM/STM)
    reg detect_d;
    always @(posedge clk or negedge rstb) begin
        if (!rstb) detect_d <= 0;
        else if (flush) detect_d <= 0;
        else detect_d <= is_block_transfer;
    end
    wire detect_edge = is_block_transfer & ~detect_d;

    // LDM/STM state machine registers
    reg active;
    reg [15:0] mask;
    reg [31:0] offset;
    reg wb_pending;
    reg [4:0]  total_regs;
    reg [3:0]  base_reg_save; 
    reg        is_load_save_reg;
    reg        u_bit_save;

    // Population count: number of registers to transfer
    wire [4:0] popcount = instr[0] + instr[1] + instr[2] + instr[3] +
                          instr[4] + instr[5] + instr[6] + instr[7] +
                          instr[8] + instr[9] + instr[10] + instr[11] +
                          instr[12] + instr[13] + instr[14] + instr[15];

    // Priority encoder to find the next register index in the mask
    wire [3:0] first_reg = mask[0]?0 : mask[1]?1 : mask[2]?2 : mask[3]?3 :
                           mask[4]?4 : mask[5]?5 : mask[6]?6 : mask[7]?7 :
                           mask[8]?8 : mask[9]?9 : mask[10]?10 : mask[11]?11 :
                           mask[12]?12 : mask[13]?13 : mask[14]?14 : 15;

    wire only_one_left = (mask != 0) && ((mask & (mask - 1)) == 16'b0);

    // LDM/STM Sequencer
    always @(posedge clk or negedge rstb) begin
        if (!rstb) begin
            active <= 0; mask <= 0; offset <= 0; wb_pending <= 0;
        end 
        else if (flush) begin 
            active <= 0; mask <= 0; wb_pending <= 0;
        end 
        else begin
            if (detect_edge) begin 
                active <= 1;
                mask <= instr[15:0];
                total_regs <= popcount;
                // Calculate initial offset based on U bit (Up/Down)
                offset <= instr[23] ? 32'd0 : (~({27'b0, popcount} << 2) + 1);
                wb_pending <= instr[21]; // Writeback bit
                base_reg_save <= instr[19:16]; 
                is_load_save_reg <= instr[20];
                u_bit_save <= instr[23];
            end 
            else if (active) begin
                if (mask != 0) begin
                    mask[first_reg] <= 0; 
                    offset <= offset + 4; 
                    if (only_one_left && !wb_pending) active <= 0;
                end 
                else if (wb_pending) begin
                    wb_pending <= 0;
                    active <= 0; 
                end
            end
        end
    end

    assign start_flush = detect_edge;
    assign stall_pipeline = active; 

    // Main Control Signal Decoder
    always @(*) begin
        alu_src = 0; alu_ctrl = 4'b0000; imm_src = 2'b00; mem_read = 0;
        mem_write = 0; reg_write = 0; mem_to_reg = 0; branch = 0; cond = cond_field;
        use_override_wa = 0; override_wa = 0; 
        use_override_rg2 = 0; override_rg2 = 0; 
        use_override_imm = 0; override_imm = 0;
        use_override_rg1 = 0; override_rg1 = 0; 

        if (active && mask != 0) begin
            // Handling individual register transfers within LDM/STM
            alu_src = 1; alu_ctrl = 4'b0000; 
            use_override_imm = 1; override_imm = offset;
            use_override_rg1 = 1; override_rg1 = base_reg_save;

            if (is_load_save_reg) begin // LDM
                mem_read = 1; mem_to_reg = 1; reg_write = 1;
                use_override_wa = 1; override_wa = first_reg;
            end else begin // STM
                mem_write = 1;
                use_override_rg2 = 1; override_rg2 = first_reg;
            end
        end 
        else if (active && mask == 0 && wb_pending) begin
            // Handling the base register writeback for LDM/STM
            alu_src = 1; alu_ctrl = 4'b0000; 
            use_override_imm = 1; 
            override_imm = u_bit_save ? ({27'b0, total_regs} << 2) : (~({27'b0, total_regs} << 2) + 1);
            reg_write = 1; 
            use_override_wa = 1; override_wa = base_reg_save; 
            use_override_rg1 = 1; override_rg1 = base_reg_save;
        end 
        else if (!active && !detect_edge) begin 
            // Normal Instruction Decoding
            if (op_high == 3'b101) begin // Branch
                branch  = 1; imm_src = 2'b10;  
                if (link_bit) reg_write = 1; 
            end else if (op_mid == 2'b01) begin // Load/Store
                alu_src = ~I_bit; imm_src = 2'b01;    
                alu_ctrl = U_bit ? 4'b0000 : 4'b0001;  
                if (L_bit) begin
                    mem_read = 1; mem_to_reg = 1; reg_write = 1;
                end else mem_write = 1;
            end else if (op_mid == 2'b00) begin // Data Processing
                if (instr[27:4] == 24'b000100101111111111110001) branch = 1; // BX
                else begin
                    alu_src = I_bit; imm_src = 2'b00;   
                    case (opcode)
                        4'b0100: begin alu_ctrl = 4'b0000; reg_write = 1; end // ADD
                        4'b0010: begin alu_ctrl = 4'b0001; reg_write = 1; end // SUB
                        4'b1010: begin alu_ctrl = 4'b0001; reg_write = 0; end // CMP
                        4'b1101: begin alu_ctrl = 4'b0010; reg_write = 1; end // MOV
                    endcase
                end
            end
        end
    end
endmodule

// ==========================================
// 5. Register File (RF) - Hardware MMU Partitioned
// ==========================================
module register_file (rg1, rg2, wd, wa, wen, w_thread, thread, r1data, r2data, clk, rst);
    input wire clk, rst, wen;
    input wire [1:0] thread, w_thread;
    input wire [3:0] rg1, rg2, wa;
    input wire [31:0] wd;
    output wire [31:0] r1data, r2data;

    // Total 64 registers (16 registers per thread * 4 threads)
    reg [31:0] regfile [0:63];
    wire [5:0] r1, r2, w1;
    assign r1 = {thread, rg1};
    assign r2 = {thread, rg2};
    assign w1 = {w_thread, wa};

    // Internal forwarding for Register File
    assign r1data = (wen && (w1 == r1)) ? wd : regfile[r1];
    assign r2data = (wen && (w1 == r2)) ? wd : regfile[r2];

    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1) begin
            regfile[i] = 32'b0;
        end
        // Since we have hardware-level memory partitioning, all 4 threads
        // can share the same logical memory map (0x0000 - 0x0FFF).
        // Therefore, we initialize all Stack Pointers (SP / R13) to 0x0FFC.
        regfile[13] = 32'h0000_0FFC; // Thread 0 SP
        regfile[29] = 32'h0000_0FFC; // Thread 1 SP
        regfile[45] = 32'h0000_0FFC; // Thread 2 SP
        regfile[61] = 32'h0000_0FFC; // Thread 3 SP
    end

    always @(posedge clk) begin
       if(wen)begin
            regfile[w1] <= wd;
       end
    end
endmodule

// ==========================================
// 6. Immediate Generator
// ==========================================
module imm_gen (instr, imm_src, imm_out);
    input  wire [31:0] instr;
    input  wire [1:0]  imm_src;
    output reg  [31:0] imm_out;

    wire [11:0] imm12  = instr[11:0];
    wire [23:0] imm24  = instr[23:0];
    wire [7:0]  imm8   = instr[7:0];
    wire [3:0]  rotate = instr[11:8];

    always @(*) begin
        case (imm_src)
            2'b00: begin // Data Processing Immediate (with rotation)
                imm_out = {24'b0, imm8} >> (rotate * 2) |
                          {24'b0, imm8} << (32 - (rotate * 2));
            end
            2'b01: begin // Load/Store Offset
                imm_out = {20'b0, imm12};
            end
            2'b10: begin // Branch Offset
                imm_out = {{6{imm24[23]}}, imm24, 2'b00};
            end
            default: begin
                imm_out = 32'b0;
            end
        endcase
    end
endmodule

// ==========================================
// 7. ID / EX Pipeline Register
// ==========================================
module id_ex_reg (clk, rstb, en, flush,id_alu_src, id_alu_ctrl,id_mem_read, id_mem_write,id_reg_write, id_mem_to_reg,
    id_branch, id_cond,id_pc, id_instr,id_r1data, id_r2data,id_imm_out, id_wa,id_thread_id,
    ex_alu_src, ex_alu_ctrl,ex_mem_read, ex_mem_write,ex_reg_write, ex_mem_to_reg, ex_branch, ex_cond,
    ex_pc, ex_instr,ex_r1data, ex_r2data,ex_imm_out, ex_wa,ex_thread_id
);
    input  wire        clk;
    input  wire        rstb;
    input  wire        en;
    input  wire        flush;

    input  wire        id_alu_src;
    input  wire [3:0]  id_alu_ctrl;
    input  wire        id_mem_read;
    input  wire        id_mem_write;
    input  wire        id_reg_write;
    input  wire        id_mem_to_reg;
    input  wire        id_branch;
    input  wire [3:0]  id_cond;
    
    input  wire [8:0]  id_pc;
    input  wire [31:0] id_instr;
    input  wire [31:0] id_r1data;
    input  wire [31:0] id_r2data;
    input  wire [31:0] id_imm_out;
    input  wire [3:0]  id_wa;        
    input  wire [1:0]  id_thread_id;

    output reg         ex_alu_src;
    output reg  [3:0]  ex_alu_ctrl;
    output reg         ex_mem_read;
    output reg         ex_mem_write;
    output reg         ex_reg_write;
    output reg         ex_mem_to_reg;
    output reg         ex_branch;
    output reg  [3:0]  ex_cond;

    output reg  [8:0]  ex_pc;
    output reg  [31:0] ex_instr;
    output reg  [31:0] ex_r1data;
    output reg  [31:0] ex_r2data;
    output reg  [31:0] ex_imm_out;
    output reg  [3:0]  ex_wa;
    output reg  [1:0]  ex_thread_id;

    always @(posedge clk or negedge rstb) begin
        if (!rstb) begin
            ex_mem_read   <= 0;
            ex_mem_write  <= 0;
            ex_reg_write  <= 0;
            ex_branch     <= 0;
            ex_thread_id  <= 2'b0;
            ex_alu_ctrl   <= 4'b0;
            ex_alu_src    <= 0;
            ex_mem_to_reg <= 0;
            ex_cond       <= 4'b1110; 
            ex_instr      <= 32'hE1A00000;
            ex_pc         <= 9'b0;
            ex_r1data     <= 32'b0;
            ex_r2data     <= 32'b0;
            ex_imm_out    <= 32'b0;
            ex_wa         <= 4'b0;
        end 
        else if (flush) begin
            ex_mem_read   <= 0;
            ex_mem_write  <= 0;
            ex_reg_write  <= 0;
            ex_branch     <= 0;
            ex_thread_id  <= 2'b0;
            ex_alu_ctrl   <= 4'b0;
            ex_alu_src    <= 0;
            ex_mem_to_reg <= 0;
            ex_cond       <= 4'b1110; 
            ex_instr      <= 32'hE1A00000;
        end 
        else if (en) begin
            ex_alu_src    <= id_alu_src;
            ex_alu_ctrl   <= id_alu_ctrl;
            ex_mem_read   <= id_mem_read;
            ex_mem_write  <= id_mem_write;
            ex_reg_write  <= id_reg_write;
            ex_mem_to_reg <= id_mem_to_reg;
            ex_branch     <= id_branch;
            ex_cond       <= id_cond;

            ex_pc         <= id_pc;
            ex_instr      <= id_instr;
            ex_r1data     <= id_r1data;
            ex_r2data     <= id_r2data;
            ex_imm_out    <= id_imm_out;
            ex_wa         <= id_wa;
            ex_thread_id  <= id_thread_id;
        end
    end
endmodule

// ==========================================
// 8. ALU
// ==========================================
module alu (A, B, alu_ctrl, result, flags);
    input  wire [31:0] A;
    input  wire [31:0] B;
    input  wire [3:0]  alu_ctrl;
    output reg  [31:0] result;
    output reg  [3:0]  flags;

    reg carry_out;
    reg overflow;

    always @(*) begin
        carry_out = 0;
        overflow  = 0;

        case (alu_ctrl)
            4'b0000: begin // ADD
                {carry_out, result} = A + B;
                overflow = (A[31] == B[31]) && (result[31] != A[31]);
            end
            4'b0001: begin // SUB
                {carry_out, result} = A - B;
                overflow = (A[31] != B[31]) && (result[31] != A[31]);
            end
            4'b0010: begin result = B; end // MOV
            4'b0011: begin result = A & B; end // AND
            4'b0100: begin result = A | B; end // OR
            4'b0101: begin result = A ^ B; end // XOR
            default: begin result = 32'b0; end
        endcase

        // Flag Generation: [3]=Negative, [2]=Zero, [1]=Carry, [0]=Overflow
        flags[3] = result[31];           
        flags[2] = (result == 32'b0);    
        flags[1] = carry_out;            
        flags[0] = overflow;             
    end
endmodule

// ==========================================
// 9. Condition Check
// ==========================================
module condition_check (cond, flags, pass);
    input  wire [3:0] cond;
    input  wire [3:0] flags;
    output reg         pass;

    wire N = flags[3];
    wire Z = flags[2];
    wire C = flags[1];
    wire V = flags[0];

    always @(*) begin
        case (cond)
            4'b0000: pass =  Z;                 // EQ
            4'b0001: pass = ~Z;                 // NE
            4'b0010: pass =  C;                 // CS
            4'b0011: pass = ~C;                 // CC
            4'b0100: pass =  N;                 // MI
            4'b0101: pass = ~N;                 // PL
            4'b0110: pass =  V;                 // VS
            4'b0111: pass = ~V;                 // VC
            4'b1000: pass =  C & ~Z;            // HI
            4'b1001: pass = ~C |  Z;            // LS
            4'b1010: pass = (N == V);           // GE
            4'b1011: pass = (N != V);           // LT
            4'b1100: pass = ~Z & (N == V);      // GT
            4'b1101: pass =  Z | (N != V);      // LE
            4'b1110: pass = 1'b1;               // AL (Always)
            default: pass = 1'b0;               
        endcase
    end
endmodule

// ==========================================
// 10. CPSR Array (Thread Flags)
// ==========================================
module cpsr_array (clk, rstb, thread_id, update_en, alu_flags, curr_flags);
    input  wire       clk;
    input  wire       rstb;
    input  wire [1:0] thread_id;  
    input  wire       update_en;  
    input  wire [3:0] alu_flags;  
    output reg  [3:0] curr_flags;  

    // Individual condition registers for each thread
    reg [3:0] cpsr_reg_0, cpsr_reg_1, cpsr_reg_2, cpsr_reg_3;

    always @(*) begin
        case (thread_id)
            2'b00: curr_flags = cpsr_reg_0;
            2'b01: curr_flags = cpsr_reg_1;
            2'b10: curr_flags = cpsr_reg_2;
            2'b11: curr_flags = cpsr_reg_3;
            default: curr_flags = 4'b0000;
        endcase
    end

    always @(posedge clk or negedge rstb) begin
        if (!rstb) begin
            cpsr_reg_0 <= 4'b0000;
            cpsr_reg_1 <= 4'b0000;
            cpsr_reg_2 <= 4'b0000;
            cpsr_reg_3 <= 4'b0000;
        end 
        else if (update_en) begin
            case (thread_id)
                2'b00: cpsr_reg_0 <= alu_flags;
                2'b01: cpsr_reg_1 <= alu_flags;
                2'b10: cpsr_reg_2 <= alu_flags;
                2'b11: cpsr_reg_3 <= alu_flags;
            endcase
        end
    end
endmodule

// ==========================================
// 11. Data Memory (DMEM) - 4-Thread Partitioned with Data Copying
// ==========================================
module data_memory (
    input  wire        clk,
    input  wire        mem_read,
    input  wire        mem_write,
    input  wire [31:0] addr,       
    input  wire [31:0] write_data, 
    output reg  [31:0] read_data,
    input  wire [1:0]  thread_id
);

    // 4096 words total (4 threads x 1024 words each)
    reg [31:0] dmem [0:4095];

    // Convert byte address to partitioned word address
    wire [11:0] word_addr = {thread_id, addr[11:2]};

    integer i;

    initial begin
        // 1. Clear all memory
        for (i = 0; i < 4096; i = i + 1) begin
            dmem[i] = 32'b0;
        end

        // 2. Load initial data from hex file (using relative path)
        $readmemh("data_init.hex", dmem, 0, 1023);

        // 3. Debug: Display first few entries after loading
        #1;
        $display("==== After data_init.hex load ====");
        for (i = 0; i < 10; i = i + 1) begin
            $display("dmem[%0d] = %h", i, dmem[i]);
        end

        // 4. Duplicate the initial data segment for the other threads
        for (i = 0; i < 1024; i = i + 1) begin
            dmem[1024 + i] = dmem[i];
            dmem[2048 + i] = dmem[i];
            dmem[3072 + i] = dmem[i];
        end
    end

    // Synchronous write
    always @(posedge clk) begin
        if (mem_write) begin
            $display("WRITE T%0d addr=%h word_addr=%h data=%h",
                     thread_id, addr, word_addr, write_data);
            dmem[word_addr] <= write_data;
        end
    end

    // Combinational read (avoids reset-traps or timing delays)
    always @(*) begin
        read_data = dmem[word_addr];
    end

endmodule

// ==========================================
// 12. EX / MEM Pipeline Register
// ==========================================
module ex_mem_reg (
    input  wire        clk,
    input  wire        rstb,
    input  wire        ex_mem_read,
    input  wire        ex_mem_write,
    input  wire        ex_reg_write,
    input  wire        ex_mem_to_reg,
    input  wire [31:0] ex_alu_result, 
    input  wire [31:0] ex_r2data,    
    input  wire [3:0]  ex_wa,        
    input  wire [1:0]  ex_thread_id,  
    output reg         mem_mem_read,
    output reg         mem_mem_write,
    output reg         mem_reg_write,
    output reg         mem_mem_to_reg,
    output reg  [31:0] mem_alu_result,
    output reg  [31:0] mem_write_data,
    output reg  [3:0]  mem_wa,
    output reg  [1:0]  mem_thread_id
);
    always @(posedge clk or negedge rstb) begin
        if (!rstb) begin
            mem_mem_read   <= 0;
            mem_mem_write  <= 0;
            mem_reg_write  <= 0;
            mem_mem_to_reg <= 0;
            mem_alu_result <= 32'b0;
            mem_write_data <= 32'b0;
            mem_wa         <= 4'b0;
            mem_thread_id  <= 2'b0;
        end else begin
            mem_mem_read   <= ex_mem_read;
            mem_mem_write  <= ex_mem_write;
            mem_reg_write  <= ex_reg_write;
            mem_mem_to_reg <= ex_mem_to_reg;
            mem_alu_result <= ex_alu_result;
            mem_write_data <= ex_r2data; 
            mem_wa         <= ex_wa;
            mem_thread_id  <= ex_thread_id;
        end
    end
endmodule

// ==========================================
// 13. MEM / WB Pipeline Register
// ==========================================
module mem_wb_reg (
    input  wire        clk,
    input  wire        rstb,
    input  wire        mem_reg_write,
    input  wire        mem_mem_to_reg,
    input  wire [31:0] mem_alu_result, 
    input  wire [31:0] mem_read_data,  
    input  wire [3:0]  mem_wa,        
    input  wire [1:0]  mem_thread_id,  
    output reg         wb_reg_write,
    output reg         wb_mem_to_reg,
    output reg  [31:0] wb_alu_result,
    output reg  [31:0] wb_read_data,
    output reg  [3:0]  wb_wa,
    output reg  [1:0]  wb_thread_id
);
    always @(posedge clk or negedge rstb) begin
        if (!rstb) begin
            wb_reg_write  <= 0;
            wb_mem_to_reg <= 0;
            wb_alu_result <= 32'b0;
            wb_read_data  <= 32'b0;
            wb_wa         <= 4'b0;
            wb_thread_id  <= 2'b0;
        end else begin
            wb_reg_write  <= mem_reg_write;
            wb_mem_to_reg <= mem_mem_to_reg;
            wb_alu_result <= mem_alu_result;
            wb_read_data  <= mem_read_data;
            wb_wa         <= mem_wa;
            wb_thread_id  <= mem_thread_id;
        end
    end
endmodule

// ==========================================
// 14. Barrel Shifter
// ==========================================
module barrel_shifter (
    input  wire [31:0] data_in,   
    input  wire [4:0]  shamt5,   
    input  wire [1:0]  sh_type,   
    output reg  [31:0] data_out   
);
    always @(*) begin
        if (shamt5 == 5'b0) begin
            data_out = data_in;
        end else begin
            case (sh_type)
                2'b00: data_out = data_in << shamt5;                 // LSL
                2'b01: data_out = data_in >> shamt5;                 // LSR
                2'b10: data_out = $signed(data_in) >>> shamt5;       // ASR
                2'b11: data_out = (data_in >> shamt5) | (data_in << (32 - shamt5)); // ROR
            endcase
        end
    end
endmodule