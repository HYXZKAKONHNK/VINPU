library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity fp64_core is
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;
        
        -- Потоковый ввод операндов FP64 (64 бита)
        valid_i  : in  std_logic;
        a_i      : in  std_logic_vector(63 downto 0);
        b_i      : in  std_logic_vector(63 downto 0);
        
        -- Потоковый вывод результата FP64
        valid_o  : out std_logic;
        result_o : out std_logic_vector(63 downto 0)
    );
end entity fp64_core;

architecture rtl of fp64_core is

    -- Ступень 1: Распаковка
    signal s1_valid : std_logic;
    signal s1_sign  : std_logic;
    signal s1_exp   : signed(11 downto 0);
    signal s1_sig_a : unsigned(52 downto 0);
    signal s1_sig_b : unsigned(52 downto 0);
    signal s1_zero  : std_logic;

    -- Ступень 2: Умножение (внутренние произведения мантисс)
    signal s2_valid : std_logic;
    signal s2_sign  : std_logic;
    signal s2_exp   : signed(11 downto 0);
    signal s2_prod  : unsigned(105 downto 0);
    signal s2_zero  : std_logic;

    -- Ступень 3: Суммирование произведений и подготовка к нормализации
    signal s3_valid : std_logic;
    signal s3_sign  : std_logic;
    signal s3_exp   : signed(11 downto 0);
    signal s3_prod  : unsigned(105 downto 0);
    signal s3_zero  : std_logic;

    -- Ступень 4: Финал (Нормализация и сборка)
    signal s4_valid : std_logic;
    signal s4_res   : std_logic_vector(63 downto 0);

begin

    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 1: РАСПАКОВКА И АНАЛИЗ ОПЕРАНДОВ (IEEE 754 Double Precision)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_exp_a, v_exp_b : unsigned(10 downto 0);
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
                s1_sign <= a_i(63) xor b_i(63);
                
                v_exp_a := unsigned(a_i(62 downto 52));
                v_exp_b := unsigned(b_i(62 downto 52));
                
                if (v_exp_a = 0 and unsigned(a_i(51 downto 0)) = 0) or 
                   (v_exp_b = 0 and unsigned(b_i(51 downto 0)) = 0) then
                    v_is_zero := '1';
                else
                    v_is_zero := '0';
                end if;
                s1_zero <= v_is_zero;

                -- Смещение bias для FP64 равно 1023
                s1_exp <= signed('0' & v_exp_a) + signed('0' & v_exp_b) - 1023;

                if v_exp_a = 0 then
                    s1_sig_a <= '0' & unsigned(a_i(51 downto 0));
                else
                    s1_sig_a <= '1' & unsigned(a_i(51 downto 0));
                end if;

                if v_exp_b = 0 then
                    s1_sig_b <= '0' & unsigned(b_i(51 downto 0));
                else
                    s1_sig_b <= '1' & unsigned(b_i(51 downto 0));
                end if;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 2 & 3: АППАРАТНОЕ УМНОЖЕНИЕ МАНТИСС (53x53 бита -> 106 бит)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            s2_valid <= '0';
            s2_sign  <= '0';
            s2_exp   <= (others => '0');
            s2_prod  <= (others => '0');
            s2_zero  <= '0';
            
            s3_valid <= '0';
            s3_sign  <= '0';
            s3_exp   <= (others => '0');
            s3_prod  <= (others => '0');
            s3_zero  <= '0';
        elsif rising_edge(clk) then
            -- Такты конвейера умножителя мантисс для снижения нагрузки на трассировку
            s2_valid <= s1_valid;
            s2_sign  <= s1_sign;
            s2_exp   <= s1_exp;
            s2_zero  <= s1_zero;
            s2_prod  <= s1_sig_a * s1_sig_b;

            s3_valid <= s2_valid;
            s3_sign  <= s2_sign;
            s3_exp   <= s2_exp;
            s3_zero  <= s2_zero;
            s3_prod  <= s2_prod;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 4: НОРМАЛИЗАЦИЯ И СБОРКА РЕЗУЛЬТАТА FP64
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_norm_sig : unsigned(51 downto 0);
        variable v_norm_exp : signed(11 downto 0);
        variable v_result   : std_logic_vector(63 downto 0);
    begin
        if rst_n = '0' then
            s4_valid <= '0';
            s4_res   <= (others => '0');
        elsif rising_edge(clk) then
            s4_valid <= s3_valid;
            if s3_valid = '1' then
                if s3_zero = '1' then
                    v_result := (others => '0');
                else
                    v_norm_exp := s3_exp;
                    
                    if s3_prod(105) = '1' then
                        v_norm_sig := s3_prod(104 downto 53);
                        v_norm_exp := v_norm_exp + 1;
                    else
                        v_norm_sig := s3_prod(103 downto 52);
                    end if;

                    -- Границы экспоненты FP64 (0..2047)
                    if v_norm_exp <= 0 then
                        v_result := s3_sign & "00000000000" & (others => '0'); -- Underflow
                    elsif v_norm_exp >= 2047 then
                        v_result := s3_sign & "11111111111" & (others => '0'); -- Overflow / Inf
                    else
                        v_result := s3_sign & std_logic_vector(v_norm_exp(10 downto 0)) & std_logic_vector(v_norm_sig);
                    end if;
                end if;
                
                s4_res <= v_result;
            end if;
        end if;
    end process;

    -- Финальные выходы
    valid_o  <= s4_valid;
    result_o <= s4_res;

end architecture rtl;