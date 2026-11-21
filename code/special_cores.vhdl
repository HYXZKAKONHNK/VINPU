library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity special_cores is
    generic (
        C_LANES      : integer := 16; -- Параллельных каналов скрытого слоя (Hidden Dim lanes)
        C_DATA_WIDTH : integer := 16  -- Разрядность данных (BF16 / FP16 / Fixed-point Q8.8)
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Режим работы: '0' = Attention Dot-Product & Scale, '1' = RMSNorm Variance Accumulator
        op_mode_i       : in  std_logic;
        
        -- Потоковые входы векторов
        valid_i         : in  std_logic;
        vector_a_i      : in  std_logic_vector((C_LANES * C_DATA_WIDTH) - 1 downto 0);
        vector_b_i      : in  std_logic_vector((C_LANES * C_DATA_WIDTH) - 1 downto 0);
        scale_factor_i  : in  std_logic_vector(C_DATA_WIDTH - 1 downto 0); -- 1 / sqrt(d_k) или весовой коэффициент нормализации
        
        -- Выходы тензорного ядра
        valid_o         : out std_logic;
        result_vector_o : out std_logic_vector((C_LANES * C_DATA_WIDTH) - 1 downto 0);
        scalar_acc_o    : out std_logic_vector(31 downto 0) -- 32-битный аккумулятор (для сумм внимания или дисперсии)
    );
end entity special_cores;

architecture rtl of special_cores is

    -- Типы для массивов данных
    type t_data_array is array (0 to C_LANES-1) of signed(C_DATA_WIDTH-1 downto 0);
    type t_prod_array is array (0 to C_LANES-1) of signed((2*C_DATA_WIDTH)-1 downto 0);

    signal a_arr, b_arr : t_data_array;
    
    -- Ступень 1: Умножения / Квадраты
    signal mult_res_s1  : t_prod_array;
    signal scale_s1     : signed(C_DATA_WIDTH-1 downto 0);
    signal mode_s1      : std_logic;
    signal valid_s1     : std_logic;

    -- Ступень 2: Дерево суммирования (Adder Tree)
    signal sum_tree_s2  : signed(31 downto 0);
    signal scaled_v_s2  : t_data_array;
    signal mode_s2      : std_logic;
    signal valid_s2     : std_logic;

    -- Ступень 3: Финальный аккумулятор и нормализация
    signal accumulator  : signed(31 downto 0);
    signal final_vec    : t_data_array;
    signal valid_s3     : std_logic;

begin

    ----------------------------------------------------------------------------
    -- РАСПАКОВКА ВХОДНЫХ ВЕКТОРОВ
    ----------------------------------------------------------------------------
    process(vector_a_i, vector_b_i, scale_factor_i)
    begin
        for i in 0 to C_LANES-1 loop
            a_arr(i) <= signed(vector_a_i((i+1)*C_DATA_WIDTH - 1 downto i*C_DATA_WIDTH));
            b_arr(i) <= signed(vector_b_i((i+1)*C_DATA_WIDTH - 1 downto i*C_DATA_WIDTH));
        end loop;
        scale_s1 <= signed(scale_factor_i);
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 1: ПАРАЛЛЕЛЬНОЕ УМНОЖЕНИЕ (Mode 0: A * B | Mode 1: A * A для RMSNorm)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            valid_s1 <= '0';
            mode_s1  <= '0';
            for i in 0 to C_LANES-1 loop
                mult_res_s1(i) <= (others => '0');
            end loop;
        elsif rising_edge(clk) then
            valid_s1 <= valid_i;
            mode_s1  <= op_mode_i;
            
            if valid_i = '1' then
                for i in 0 to C_LANES-1 loop
                    if op_mode_i = '0' then
                        -- Режим 0: Скалярное произведение Q * K
                        mult_res_s1(i) <= a_arr(i) * b_arr(i);
                    else
                        -- Режим 1: Возведение в квадрат для дисперсии RMSNorm (A^2)
                        mult_res_s1(i) <= a_arr(i) * a_arr(i);
                    end if;
                end loop;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 2: ДЕРЕВО СУММИРОВАНИЯ И ПОЭЛЕМЕНТНОЕ МАСШТАБИРОВАНИЕ
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_total_sum : signed(31 downto 0);
        variable v_scaled_elem : signed(2 * C_DATA_WIDTH - 1 downto 0);
    begin
        if rst_n = '0' then
            valid_s2 <= '0';
            mode_s2  <= '0';
            sum_tree_s2 <= (others => '0');
            for i in 0 to C_LANES-1 loop
                scaled_v_s2(i) <= (others => '0');
            end loop;
        elsif rising_edge(clk) then
            valid_s2 <= valid_s1;
            mode_s2  <= mode_s1;
            
            if valid_s1 = '1' then
                v_total_sum := (others => '0');
                for i in 0 to C_LANES-1 loop
                    -- Суммируем все элементы в единый аккумулятор (скаляр или дисперсия)
                    v_total_sum := v_total_sum + resize(mult_res_s1(i), 32);
                    
                    -- Параллельное умножение вектора на коэффициент масштабирования (Scale / QK^T * 1/sqrt(d_k))
                    v_scaled_elem := mult_res_s1(i) * scale_s1;
                    scaled_v_s2(i) <= v_scaled_elem(C_DATA_WIDTH + 7 downto 8); -- Нормализация разрядности
                end loop;
                sum_tree_s2 <= v_total_sum;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 3: ФИНАЛЬНЫЙ АККУМУЛЯТОР И ФОРМИРОВАНИЕ ВЫХОДОВ
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            valid_s3 <= '0';
            accumulator <= (others => '0');
            for i in 0 to C_LANES-1 loop
                final_vec(i) <= (others => '0');
            end loop;
        elsif rising_edge(clk) then
            valid_s3 <= valid_s2;
            if valid_s2 = '1' then
                accumulator <= sum_tree_s2;
                for i in 0 to C_LANES-1 loop
                    final_vec(i) <= scaled_v_s2(i);
                end loop;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- ВЫХОДЫ МОДУЛЯ
    ----------------------------------------------------------------------------
    valid_o <= valid_s3;
    scalar_acc_o <= std_logic_vector(accumulator);

    process(final_vec)
    begin
        for i in 0 to C_LANES-1 loop
            result_vector_o((i+1)*C_DATA_WIDTH - 1 downto i*C_DATA_WIDTH) <= std_logic_vector(final_vec(i));
        end loop.
    end process;

end architecture rtl;