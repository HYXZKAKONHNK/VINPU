library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vinpu_arch_pkg.all;

entity numpy_accelerator is
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        
        -- BAR0 Control & Command Interface
        cmd_valid   : in  std_logic;
        cmd_opcode  : in  std_logic_vector(3 downto 0); -- 0001: MatMul, 0010: Add, 003: Relu/Activation
        dim_m       : in  std_logic_vector(15 downto 0); -- Rows of A / Result
        dim_n       : in  std_logic_vector(15 downto 0); -- Cols of B / Result
        dim_k       : in  std_logic_vector(15 downto 0); -- Inner dimension for Dot
        cmd_ready   : out std_logic;
        
        -- DMA / Memory Interface to DDR3L Arbiter
        mem_addr_a  : out std_logic_vector(31 downto 0);
        mem_addr_b  : out std_logic_vector(31 downto 0);
        mem_addr_c  : out std_logic_vector(31 downto 0);
        mem_rd_en   : out std_logic;
        mem_wr_en   : out std_logic;
        mem_data_in : in  std_logic_vector(127 downto 0);
        mem_data_out: out std_logic_vector(127 downto 0);
        mem_busy    : in  std_logic;
        
        -- Interrupt / Status
        done        : out std_logic
    );
end entity numpy_accelerator;

architecture rtl of numpy_accelerator is

    -- State Machine for Matrix Operations (Strides, Loop counters)
    type state_t is (IDLE, FETCH_A, FETCH_B, COMPUTE, WRITEBACK, DONE_STATE);
    signal current_state : state_t;
    
    -- Internal MAC array control signals
    signal row_counter : unsigned(15 downto 0);
    signal col_counter : unsigned(15 downto 0);
    signal k_counter   : unsigned(15 downto 0);
    
begin

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            current_state <= IDLE;
            cmd_ready     <= '1';
            done          <= '0';
            row_counter   <= (others => '0');
            col_counter   <= (others => '0');
            k_counter     <= (others => '0');
            mem_rd_en     <= '0';
            mem_wr_en     <= '0';
        elsif rising_edge(clk) then
            case current_state is
                when IDLE =>
                    done <= '0';
                    if cmd_valid = '1' then
                        cmd_ready     <= '0';
                        current_state <= FETCH_A;
                        row_counter   <= (others => '0');
                        col_counter   <= (others => '0');
                        k_counter     <= (others => '0');
                    end if;
                    
                when FETCH_A =>
                    -- Запрос данных матриц из DDR3L по адресам с учетом strided-формата
                    if mem_busy = '0' then
                        mem_rd_en     <= '1';
                        current_state <= COMPUTE;
                    end if;
                    
                when COMPUTE =>
                    mem_rd_en <= '0';
                    -- Аппаратные MAC-ядра перемалывают элементы
                    -- (здесь задействуются наши special_cores.vhdl и тензорные блоки)
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