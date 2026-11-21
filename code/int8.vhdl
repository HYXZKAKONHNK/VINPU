library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity int8_core is
    generic (
        C_LANES : integer := 16 -- Количество параллельных каналов MAC (мапится на DSP48E1 в Artix-7)
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        
        -- Управление вычислением
        accumulate_i  : in  std_logic; -- '1': суммировать с текущим аккумулятором, '0': сбросить и начать новый агр.
        
        -- Потоковый ввод (AXI-Stream like)
        valid_i       : in  std_logic;
        weights_i     : in  std_logic_vector((C_LANES * 8) - 1 downto 0); -- Вектор весов INT8
        activations_i : in  std_logic_vector((C_LANES * 8) - 1 downto 0); -- Вектор активаций INT8
        
        -- Выход результата (INT32 аккумулятор)
        valid_o       : out std_logic;
        result_o      : out std_logic_vector(31 downto 0)
    );
end entity int8_core;

architecture rtl of int8_core is

    -- Типы для массивов векторов со знаком
    type t_int8_array  is array (0 to C_LANES-1) of signed(7 downto 0);
    type t_int16_array is array (0 to C_LANES-1) of signed(15 downto 0);
    
    signal w_arr : t_int8_array;
    signal a_arr : t_int8_array;
    
    -- Ступень 1: Конвейерные регистры параллельного умножения INT8 * INT8 -> INT16
    signal mult_res      : t_int16_array;
    signal stage1_valid  : std_logic;
    
    -- Ступень 2: Дерево суммирования (Adder Tree)
    signal sum_stage2    : signed(31 downto 0);
    signal stage2_valid  : std_logic;
    
    -- Ступень 3: Накопитель (Accumulator) для GEMM / Conv
    signal accumulator   : signed(31 downto 0);

begin

    ----------------------------------------------------------------------------
    -- 1. РАСПАКОВКА ВХОДНЫХ ПАКЕТНЫХ ДАННЫХ В МАССИВЫ СИГНАЛОВ
    ----------------------------------------------------------------------------
    process(weights_i, activations_i)
    begin
        for i in 0 to C_LANES-1 loop
            w_arr(i) <= signed(weights_i((i+1)*8 - 1 downto i*8));
            a_arr(i) <= signed(activations_i((i+1)*8 - 1 downto i*8));
        end loop;
    end process;


    ----------------------------------------------------------------------------
    -- 2. СТУПЕНЬ 1: ПАРАЛЛЕЛЬНОЕ УМНОЖЕНИЕ (Инференсится в DSP48E1)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            for i in 0 to C_LANES-1 loop
                mult_res(i) <= (others => '0');
            end loop;
            stage1_valid <= '0';
        elsif rising_edge(clk) then
            stage1_valid <= valid_i;
            if valid_i = '1' then
                for i in 0 to C_LANES-1 loop
                    mult_res(i) <= w_arr(i) * a_arr(i);
                end loop;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- 3. СТУПЕНЬ 2: ДЕРЕВО СУММИРОВАНИЯ (ADDER TREE) ДЛЯ ВСЕХ КАНАЛОВ
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_sum : signed(31 downto 0);
    begin
        if rst_n = '0' then
            sum_stage2   <= (others => '0');
            stage2_valid <= '0';
            accumulator  <= (others => '0');
            valid_o      <= '0';
            result_o     <= (others => '0');
        elsif rising_edge(clk) then
            stage2_valid <= stage1_valid;
            if stage1_valid = '1' then
                v_sum := (others => '0');
                for i in 0 to C_LANES-1 loop
                    v_sum := v_sum + resize(mult_res(i), 32);
                end loop;
                sum_stage2 <= v_sum;
            end if;

            -- Ступень 3: Накопление результата (для матричных блоков GEMM)
            valid_o <= stage2_valid;
            if stage2_valid = '1' then
                if accumulate_i = '1' then
                    accumulator <= accumulator + sum_stage2;
                else
                    accumulator <= sum_stage2;
                end if;
                result_o <= std_logic_vector(accumulator + sum_stage2);
            end if;
        end if;
    end process;

    -- Исправленный закрывающий блок синтаксиса для Vivado (end if вместо сиф)
    -- (Ниже чистый блок без опечаток)

end architecture rtl;