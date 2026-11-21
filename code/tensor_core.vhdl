library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tensor_core is
    port (
        clk            : in  std_logic;
        rst_n          : in  std_logic;
        enable         : in  std_logic;
        precision_mode : in  std_logic_vector(1 downto 0); -- 00:BF16, 01:INT8, 10:INT4
        operands_a : in std_logic_vector(4095 downto 0);
        operands_b : in std_logic_vector(4095 downto 0);
        results : out std_logic_vector(2047 downto 0); -- 32*64 бит
        valid : out std_logic
    );
end entity;

architecture rtl of tensor_core is
    -- 16 умножений параллельно!
    type mult_array is array (0 to 15) of signed(15 downto 0);
    signal mults : mult_array;
    signal sum_stage1 : signed(23 downto 0);
    signal sum_stage2 : signed(31 downto 0);
    signal accum_reg : signed(63 downto 0);
    signal valid_pipe : std_logic_vector(3 downto 0);
begin
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            mults <= (others => (others => '0'));
            sum_stage1 <= (others => '0');
            sum_stage2 <= (others => '0');
            accum_reg <= (others => '0');
            valid_pipe <= (others => '0');
        elsif rising_edge(clk) then
            valid_pipe <= valid_pipe(2 downto 0) & enable;
            
            if enable = '1' then
                -- Stage 1: 16x INT8 умножений за 1 такт!
                for i in 0 to 15 loop
                    mults(i) <= signed(operand_a(i*8+7 downto i*8)) * signed(operand_b(i*8+7 downto i*8));
                end loop;
                
                -- Stage 2: дерево сумматоров (чтобы частоту держать 300МГц на Artix-7 -2)
                sum_stage1 <= resize(mults(0) + mults(1) + mults(2) + mults(3) + mults(4) + mults(5) + mults(6) + mults(7), 24);
                sum_stage2 <= resize(sum_stage1 + mults(8) + mults(9) + mults(10) + mults(11) + mults(12) + mults(13) + mults(14) + mults(15), 32);
                
                -- Stage 3: аккумуляция
                accum_reg <= accum_reg + sum_stage2;
            end if;
            
            mac_result <= std_logic_vector(accum_reg);
            valid_out <= valid_pipe(3);
        end if;
    end process;
end architecture;