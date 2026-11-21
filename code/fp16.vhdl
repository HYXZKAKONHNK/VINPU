library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity fp16_core is
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;
        
        -- Потоковый ввод операндов FP16
        valid_i  : in  std_logic;
        a_i      : in  std_logic_vector(15 downto 0);
        b_i      : in  std_logic_vector(15 downto 0);
        
        -- Потоковый вывод результата FP16
        valid_o  : out std_logic;
        result_o : out std_logic_vector(15 downto 0)
    );
end entity fp16_core;

architecture rtl of fp16_core is

    -- Конвейерные регистры - Ступень 1
    signal s1_valid : std_logic;
    signal s1_sign  : std_logic;
    signal s1_exp   : signed(6 downto 0);
    signal s1_sig_a : unsigned(10 downto 0);
    signal s1_sig_b : unsigned(10 downto 0);
    signal s1_zero  : std_logic;

    -- Конвейерные регистры - Ступень 2
    signal s2_valid : std_logic;
    signal s2_sign  : std_logic;
    signal s2_exp   : signed(6 downto 0);
    signal s2_prod  : unsigned(21 downto 0);
    signal s2_zero  : std_logic;

    -- Конвейерные регистры - Ступень 3 (Финальная)
    signal s3_valid : std_logic;
    signal s3_res   : std_logic_vector(15 downto 0);

begin

    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 1: РАСПАКОВКА И АНАЛИЗ ОПЕРАНДОВ (IEEE 754 Half Precision)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_exp_a, v_exp_b : unsigned(4 downto 0);
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
                s1_sign <= a_i(15) xor b_i(15);
                
                v_exp_a := unsigned(a_i(14 downto 10));
                v_exp_b := unsigned(b_i(14 downto 10));
                
                -- Проверка на ноль
                if (v_exp_a = 0 and unsigned(a_i(9 downto 0)) = 0) or 
                   (v_exp_b = 0 and unsigned(b_i(9 downto 0)) = 0) then
                    v_is_zero := '1';
                else
                    v_is_zero := '0';
                end if;
                s1_zero <= v_is_zero;

                -- Сложение экспонент с вычетом смещения (bias = 15 для FP16)
                s1_exp <= signed('0' & v_exp_a) + signed('0' & v_exp_b) - 15;

                -- Добавление скрытого бита '1' для нормализованных чисел
                if v_exp_a = 0 then
                    s1_sig_a <= '0' & unsigned(a_i(9 downto 0));
                else
                    s1_sig_a <= '1' & unsigned(a_i(9 downto 0));
                end if;

                if v_exp_b = 0 then
                    s1_sig_b <= '0' & unsigned(b_i(9 downto 0));
                else
                    s1_sig_b <= '1' & unsigned(b_i(9 downto 0));
                end if;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 2: УМНОЖЕНИЕ МАНТИСС (11x11 бит -> 22 бита)
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
                s2_prod <= s1_sig_a * s1_sig_b;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 3: НОРМАЛИЗАЦИЯ И СБОРКА РЕЗУЛЬТАТА
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_norm_sig : unsigned(9 downto 0);
        variable v_norm_exp : signed(6 downto 0);
        variable v_result   : std_logic_vector(15 downto 0);
    begin
        if rst_n = '0' then
            s3_valid <= '0';
            s3_res   <= (others => '0');
        elsif rising_edge(clk) then
            s3_valid <= s2_valid;
            if s2_valid = '1' then
                if s2_zero = '1' then
                    v_result := (others => '0');
                else
                    v_norm_exp := s2_exp;
                    
                    -- Нормализация позиции старшего бита
                    if s2_prod(21) = '1' then
                        v_norm_sig := s2_prod(20 downto 11);
                        v_norm_exp := v_norm_exp + 1;
                    else
                        v_norm_sig := s2_prod(19 downto 10);
                    end if;

                    -- Обработка границ экспоненты под FP16 (0..31)
                    if v_norm_exp <= 0 then
                        v_result := s2_sign & "00000" & (others => '0'); -- Underflow
                    elsif v_norm_exp >= 31 then
                        v_result := s2_sign & "11111" & (others => '0'); -- Infinity
                    else
                        v_result := s2_sign & std_logic_vector(v_norm_exp(4 downto 0)) & std_logic_vector(v_norm_sig);
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