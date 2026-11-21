library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity fp32_core is
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;
        
        -- Потоковый ввод операндов FP32
        valid_i  : in  std_logic;
        a_i      : in  std_logic_vector(31 downto 0);
        b_i      : in  std_logic_vector(31 downto 0);
        
        -- Потоковый вывод результата FP32
        valid_o  : out std_logic;
        result_o : out std_logic_vector(31 downto 0)
    );
end entity fp32_core;

architecture rtl of fp32_core is

    -- Конвейерные регистры - Ступень 1
    signal s1_valid : std_logic;
    signal s1_sign  : std_logic;
    signal s1_exp   : signed(8 downto 0);
    signal s1_sig_a : unsigned(23 downto 0);
    signal s1_sig_b : unsigned(23 downto 0);
    signal s1_zero  : std_logic;

    -- Конвейерные регистры - Ступень 2
    signal s2_valid : std_logic;
    signal s2_sign  : std_logic;
    signal s2_exp   : signed(8 downto 0);
    signal s2_prod  : unsigned(47 downto 0);
    signal s2_zero  : std_logic;

    -- Конвейерные регистры - Ступень 3 (Финальная)
    signal s3_valid : std_logic;
    signal s3_res   : std_logic_vector(31 downto 0);

begin

    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 1: РАСПАКОВКА И АНАЛИЗ ОПЕРАНДОВ (IEEE 754 Single Precision)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_exp_a, v_exp_b : unsigned(7 downto 0);
        variable v_is_zero        : std_logic;
    begin
        if rst_n = '0' then
            s1_valid <= '0';
            s1_sign  <= '0';
            s1_exp   <= (others => '0');
            s1_sig_a <= (others => '0');
            s1_sig_b <= (others => '0');
            s1_zero  <= '0';
        elsif rising_edge(clk) then
            s1_valid <= valid_i;
            if valid_i = '1' then
                s1_sign <= a_i(31) xor b_i(31);
                
                v_exp_a := unsigned(a_i(30 downto 23));
                v_exp_b := unsigned(b_i(30 downto 23));
                
                -- Проверка на ноль (если один из операндов равен 0 по экспоненте и мантиссе)
                if (v_exp_a = 0 and unsigned(a_i(22 downto 0)) = 0) or 
                   (v_exp_b = 0 and unsigned(b_i(22 downto 0)) = 0) then
                    v_is_zero := '1';
                else
                    v_is_zero := '0';
                end if;
                s1_zero <= v_is_zero;

                -- Суммирование экспонент с вычетом смещения (bias = 127)
                -- Формат signed(8 downto 0) позволяет избежать переполнения при сложении
                s1_exp <= signed('0' & v_exp_a) + signed('0' & v_exp_b) - 127;

                -- Добавление скрытого бита '1' для нормализованных чисел IEEE 754
                if v_exp_a = 0 then
                    s1_sig_a <= '0' & unsigned(a_i(22 downto 0)); -- Денормализованное
                else
                    s1_sig_a <= '1' & unsigned(a_i(22 downto 0));
                end if;

                if v_exp_b = 0 then
                    s1_sig_b <= '0' & unsigned(b_i(22 downto 0));
                else
                    s1_sig_b <= '1' & unsigned(b_i(22 downto 0));
                end if;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 2: АППАРАТНОЕ УМНОЖЕНИЕ МАНТИСС (24x24 бита -> 48 бит в DSP48E1)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            s2_valid <= '0';
            s2_sign  <= '0';
            s2_exp   <= (others => '0');
            s2_prod  <= (others => '0');
            s2_zero  <= '0';
        elsif rising_edge(clk) then
            s2_valid <= s1_valid;
            if s1_valid = '1' then
                s2_sign <= s1_sign;
                s2_exp  <= s1_exp;
                s2_zero <= s1_zero;
                -- Инференсится напрямую в каскад умножителей DSP48E1 кристалла Artix-7
                s2_prod <= s1_sig_a * s1_sig_b;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 3: НОРМАЛИЗАЦИЯ, ОКРУГЛЕНИЕ И СБОРКА РЕЗУЛЬТАТА
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_norm_sig : unsigned(22 downto 0);
        variable v_norm_exp : signed(8 downto 0);
        variable v_result   : std_logic_vector(31 downto 0);
    begin
        if rst_n = '0' then
            s3_valid <= '0';
            s3_res   <= (others => '0');
        elsif rising_edge(clk) then
            s3_valid <= s2_valid;
            if s2_valid = '1' then
                if s2_zero = '1' then
                    v_result := (others => '0'); -- Результат ноль
                else
                    v_norm_exp := s2_exp;
                    
                    -- Нормализация позиции старшего бита мантиссы (бит 47 или 46)
                    if s2_prod(47) = '1' then
                        v_norm_sig := s2_prod(46 downto 24);
                        v_norm_exp := v_norm_exp + 1;
                    else
                        v_norm_sig := s2_prod(45 downto 23);
                    end if;

                    -- Проверка на переполнение / андерфлоу экспоненты
                    if v_norm_exp <= 0 then
                        v_result := s2_sign & x"00" & (others => '0'); -- Поднуление (Underflow)
                    elsif v_norm_exp >= 255 then
                        v_result := s2_sign & x"FF" & (others => '0'); -- Бесконечность (Overflow)
                    else
                        v_result := s2_sign & std_logic_vector(v_norm_exp(7 downto 0)) & std_logic_vector(v_norm_sig);
                    end if;
                end if;
                
                s3_res <= v_result;
            end if;
        end if;
    end process;

    -- Финальные выходы
    valid_o  <= s3_valid;
    result_o <= s3_res;

end architecture rtl;