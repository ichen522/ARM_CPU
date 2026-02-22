`timescale 1ns/100ps

module tb_pipelinepc();

    reg clk;
    reg rstb;
    
    // Added: Connect software control signals that were previously dangling
    reg [31:0] sw_reset;
    reg [31:0] sw_mem_addr;
    reg [31:0] sw_mem_wdata;
    reg [31:0] sw_mem_cmd;

    // Added: Receive CPU output signals (included for design rigor, though not explicitly used)
    wire [31:0] hw_mem_rdata;
    wire [31:0] hw_pc;
    wire [31:0] hw_instr;

    //--------------------------------------------------
    // Instantiate DUT (Complete Port Mapping)
    //--------------------------------------------------
    pipelinepc uut (
        .clk(clk),
        .rstb(rstb),
        .sw_reset(sw_reset),
        .sw_mem_addr(sw_mem_addr),
        .sw_mem_wdata(sw_mem_wdata),
        .sw_mem_cmd(sw_mem_cmd),
        .hw_mem_rdata(hw_mem_rdata),
        .hw_pc(hw_pc),
        .hw_instr(hw_instr)
    );

    //--------------------------------------------------
    // Clock generation (10ns period)
    //--------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //--------------------------------------------------
    // Reset and simulation control
    //--------------------------------------------------
    initial begin
        // 🌟 CRITICAL: Initialize all software interface signals to 0 
        // to prevent 'X' (unknown) states in the simulation.
        sw_reset = 32'd0;
        sw_mem_addr = 32'd0;
        sw_mem_wdata = 32'd0;
        sw_mem_cmd = 32'd0;

        rstb = 0;
        #20;
        rstb = 1;

        // Extend simulation time to allow Bubble Sort enough cycles to complete 
        // (300,000 ns = 30,000 clock cycles)
        #30000;

        $display("=======================================");
        $display("Simulation finished. Dumping memory...");
        $display("=======================================");

        // Dump Data Memory (Verify the hierarchical path if your module names differ)
        $writememh("data_dump.hex", uut.DMem.dmem);

        $finish;
    end

    //--------------------------------------------------
    // Debug print: show PC and instruction
    //--------------------------------------------------
    always @(posedge clk) begin
        if (rstb) begin
            $display("TIME=%0t | Thread=%0d | PC=%0h | INST=%0h",
                     $time,
                     uut.thread_id_reg,
                     uut.PC.current_pc,
                     uut.IMEM.inst);
        end
    end

endmodule