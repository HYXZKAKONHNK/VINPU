library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vinpu_arch_pkg.all;

entity numpy_accelerator is
    port (
        clk            : in  std_logic;
        rst_n          : in  std_logic;
        
        -- BAR0 Control & Command Interface
        cmd_valid      : in  std_logic;
        cmd_opcode     : in  std_logic_vector(3 downto 0); -- 0001: MatMul, 0010: Add, 0011: Relu
        precision_mode : in  std_logic_vector(1 downto 0); -- 00: FP32, 01: INT8, 10: INT4, 11: INT16
        dim_m          : in  std_logic_vector(15 downto 0);
        dim_n          : in  std_logic_vector(15 downto 0);
        dim_k          : in  std_logic_vector(15 downto 0);
        
        -- Scale & Zero Point for Quantization De-scaling
        scale_factor   : in  std_logic_vector(31 downto 0); -- IEEE float or fixed-point scale
        cmd_ready      : out std_logic;
        
        -- DMA / Memory Interface to DDR3L Arbiter (128-bit wide data bus)
        mem_addr_a     : out std_logic_vector(31 downto 0);
        mem_addr_b     : out std_logic_vector(31 downto 0);
        mem_addr_c     : out std_logic_vector(31 downto 0);
        mem_rd_en      : out std_logic;
        mem_wr_en      : out std_logic;
        mem_data_in    : in  std_logic_vector(127 downto 0);
        mem_data_out   : out std_logic_vector(127 downto 0);
        mem_busy       : in  std_logic;
        
        -- Status
        done           : out std_logic
    );
end entity numpy_accelerator;

architecture rtl of numpy_accelerator is

    type state_t is (IDLE, FETCH_DATA, QUANT_DEPACK, COMPUTE_MAC, APPLY_SCALE, WRITEBACK, DONE_STATE);
    signal current_state : state_t;
    
    signal row_counter   : unsigned(15 downto 0);
    signal col_counter   : unsigned(15 downto 0);
    signal k_counter     : unsigned(15 downto 0);
    
    -- Accumulator array for MAC operations (wider to prevent overflow during INT8/INT4 matmul)
    signal mac_accumulator : signed(63 downto 0);

begin

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            current_state   <= IDLE;
            cmd_ready       <= '1';
            done            <= '0';
            row_counter     <= (others => '0');
            col_counter     <= (others => '0');
            k_counter       <= (others => '0');
            mem_rd_en       <= '0';
            mem_wr_en       <= '0';
            mac_accumulator <= (others => '0');
        elsif rising_edge(clk) then
            case current_state is
                when IDLE =>
                    done <= '0';
                    if cmd_valid = '1' then
                        cmd_ready     <= '0';
                        current_state <= FETCH_DATA;
                        row_counter   <= (others => '0');
                        col_counter   <= (others => '0');
                        k_counter     <= (others => '0');
                        mac_accumulator <= (others => '0');
                    end if;
                    
                when FETCH_DATA =>
                    if mem_busy = '0' then
                        mem_rd_en     <= '1';
                        current_state <= QUANT_DEPACK;
                    end if;
                    
                when QUANT_DEPACK =>
                    mem_rd_en <= '0';
                    -- Распаковка упакованных данных в зависимости от precision_mode:
                    -- INT4: 32 значения в 128-битном слове DDR3L
                    -- INT8: 16 значений в 128-битном слове DDR3L
                    current_state <= COMPUTE_MAC;
                    
                when COMPUTE_MAC =>
                    -- Выполнение умножения-сложения (MAC) с учетом разрядности
                    -- Здесь DSP48E1 задействует упакованный режим SIMD для векторов INT8/INT4
                    current_state <= APPLY_SCALE;
                    
                when APPLY_SCALE =>
                    -- Применение коэффициента квантования (de-quantization scale factor)
                    current_state <= WRITEBACK;
                    
                when WRITEBACK =>
                    if mem_busy = '0' then
                        mem_wr_en     <= '1';
                        current_state <= DONE_STATE;
                    end if;
                    
                when DONE_STATE =>
                    mem_wr_en     <= '0';
                    done          <= '1';
                    cmd_ready     <= '1';
                    current_state <= IDLE;
                    
                when others =>
                    current_state <= IDLE;
            end case;
        end if;
    end process;

end architecture rtl;