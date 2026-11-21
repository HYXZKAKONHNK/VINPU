library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity svg_hybrid_core is
    generic (
        C_VECTOR_LANES : integer := 8 -- Количество параллельных конвейеров Безье / Сплайнов (на DSP48E1)
    );
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;

        -- Переключатель режима: '0' = GPU (SVG Bezier / 2D Transform), '1' = NPU (KAN Spline / RoPE)
        mode_gpu_npu_i   : in  std_logic;

        -- Потоковый вход (координаты контрольных точек P0, P1, P2 или узлы сплайна/активации)
        valid_i          : in  std_logic;
        param_t_i        : in  std_logic_vector((C_VECTOR_LANES * 16) - 1 downto 0); -- Параметр t [0..1] в Q0.16 или вход X
        ctrl_p0_i        : in  std_logic_vector((C_VECTOR_LANES * 16) - 1 downto 0); -- P0 / Коэффициент C0 (Q8.8)
        ctrl_p1_i        : in  std_logic_vector((C_VECTOR_LANES * 16) - 1 downto 0); -- P1 / Коэффициент C1 (Q8.8)
        ctrl_p2_i        : in  std_logic_vector((C_VECTOR_LANES * 16) - 1 downto 0); -- P2 / Коэффициент C2 (Q8.8)

        -- Доп. вход для GPU Alpha-Blending / NPU Residual Add
        bg_or_res_i      : in  std_logic_vector((C_VECTOR_LANES * 16) - 1 downto 0);

        -- Потоковый выход (экранные координаты/альфа для pixel_rast или выход тензора для NPU)
        valid_o          : out std_logic;
        result_o         : out std_logic_vector((C_VECTOR_LANES * 16) - 1 downto 0)
    );
end entity svg_hybrid_core;

architecture rtl of svg_hybrid_core is

    -- Типы фиксированной точки (Q8.8 для координат/весов, Q0.16 для параметра интерполяции t)
    type t_q16_arr is array (0 to C_VECTOR_LANES-1) of signed(15 downto 0);
    type t_u16_arr is array (0 to C_VECTOR_LANES-1) of unsigned(15 downto 0);
    type t_q32_arr is array (0 to C_VECTOR_LANES-1) of signed(31 downto 0);

    -- Ступень 1: Вычисление базовых базисов (1 - t) и t^2 / разности для схемы Горнера
    signal t_s1          : t_u16_arr;
    signal one_minus_t_s1: t_u16_arr;
    signal p0_s1, p1_s1, p2_s1 : t_q16_arr;
    signal bg_s1         : t_q16_arr;
    signal mode_s1       : std_logic;
    signal valid_s1      : std_logic;

    -- Ступень 2: Квадратичные веса Бернштейна (GPU) или коэффициенты полинома a*x^2 + b*x + c (NPU)
    signal term0_s2      : t_q32_arr;
    signal term1_s2      : t_q32_arr;
    signal term2_s2      : t_q32_arr;
    signal bg_s2         : t_q16_arr;
    signal mode_s2       : std_logic;
    signal valid_s2      : std_logic;

    -- Ступень 3: Сборка кривой / сплайна
    signal curve_val_s3  : t_q16_arr;
    signal bg_s3         : t_q16_arr;
    signal mode_s3       : std_logic;
    signal valid_s3      : std_logic;

    -- Ступень 4: Финальный блендинг (GPU Alpha-Blend) или Residual-сложение (NPU Skip-Connection)
    signal final_out_s4  : t_q16_arr;
    signal valid_s4      : std_logic;

begin

    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 1: ПОДГОТОВКА ПАРАМЕТРОВ (GPU: (1-t) | NPU: Вход X)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_t : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            valid_s1 <= '0';
            mode_s1  <= '0';
        elsif rising_edge(clk) then
            valid_s1 <= valid_i;
            mode_s1  <= mode_gpu_npu_i;

            for i in 0 to C_VECTOR_LANES-1 loop
                v_t := unsigned(param_t_i((i+1)*16 - 1 downto i*16));
                t_s1(i)           <= v_t;
                one_minus_t_s1(i) <= x"FFFF" - v_t; -- 1.0 - t в формате Q0.16

                p0_s1(i) <= signed(ctrl_p0_i((i+1)*16 - 1 downto i*16));
                p1_s1(i) <= signed(ctrl_p1_i((i+1)*16 - 1 downto i*16));
                p2_s1(i) <= signed(ctrl_p2_i((i+1)*16 - 1 downto i*16));
                bg_s1(i) <= signed(bg_or_res_i((i+1)*16 - 1 downto i*16));
            end loop;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 2: УМНОЖЕНИЕ НА DSP48E1
    -- GPU: Квадратичная кривая Безье B(t) = (1-t)^2*P0 + 2*t*(1-t)*P1 + t^2*P2
    -- NPU: Полином/Сплайн S(x) = P2*x^2 + P1*x + P0
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_omt2 : unsigned(31 downto 0);
        variable v_2tomt: unsigned(31 downto 0);
        variable v_t2   : unsigned(31 downto 0);
        variable v_x_sq : signed(31 downto 0);
        variable v_x_s  : signed(15 downto 0);
    begin
        if rst_n = '0' then
            valid_s2 <= '0';
            mode_s2  <= '0';
        elsif rising_edge(clk) then
            valid_s2 <= valid_s1;
            mode_s2  <= mode_s1;
            bg_s2    <= bg_s1;

            for i in 0 to C_VECTOR_LANES-1 loop
                if mode_s1 = '0' then
                    -- РЕЖИМ GPU: Полиномы Бернштейна для кривых Безье
                    v_omt2  := one_minus_t_s1(i) * one_minus_t_s1(i);         -- (1-t)^2
                    v_2tomt := shift_left(t_s1(i) * one_minus_t_s1(i), 1);    -- 2*t*(1-t)
                    v_t2    := t_s1(i) * t_s1(i);                             -- t^2

                    term0_s2(i) <= signed('0' & v_omt2(31 downto 17))  * p0_s1(i);
                    term1_s2(i) <= signed('0' & v_2tomt(31 downto 17)) * p1_s1(i);
                    term2_s2(i) <= signed('0' & v_t2(31 downto 17))    * p2_s1(i);
                else
                    -- РЕЖИМ NPU: Аппаратный B-сплайн / KAN / RoPE-интерполятор
                    v_x_s  := signed(t_s1(i));
                    v_x_sq := v_x_s * v_x_s; -- x^2

                    term0_s2(i) <= shift_left(resize(p0_s1(i), 32), 8);           -- C0 (свободный член)
                    term1_s2(i) <= p1_s1(i) * v_x_s;                              -- C1 * x
                    term2_s2(i) <= p2_s1(i) * resize(shift_right(v_x_sq, 8), 16); -- C2 * x^2
                end if;
            end loop;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 3: СУММИРОВАНИЕ ЧЛЕНОВ КРИВОЙ / СПЛАЙНА
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_sum : signed(31 downto 0);
    begin
        if rst_n = '0' then
            valid_s3 <= '0';
            mode_s3  <= '0';
        elsif rising_edge(clk) then
            valid_s3 <= valid_s2;
            mode_s3  <= mode_s2;
            bg_s3    <= bg_s2;

            for i in 0 to C_VECTOR_LANES-1 loop
                v_sum := term0_s2(i) + term1_s2(i) + term2_s2(i);
                -- Нормализация обратно в Q8.8
                if mode_s2 = '0' then
                    curve_val_s3(i) <= v_sum(30 downto 15);
                else
                    curve_val_s3(i) <= v_sum(23 downto 8);
                end if;
            end loop;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- СТУПЕНЬ 4: ПОСТ-ОБРАБОТКА (GPU: Alpha-Blending | NPU: Residual Add)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            valid_s4 <= '0';
        elsif rising_edge(clk) then
            valid_s4 <= valid_s3;

            for i in 0 to C_VECTOR_LANES-1 loop
                if mode_s3 = '0' then
                    -- GPU: Смешивание с фоном / антиалиасинг субпикселя (усреднение с bg)
                    final_out_s4(i) <= shift_right(curve_val_s3(i) + bg_s3(i), 1);
                else
                    -- NPU: Аппаратный Skip-Connection (y = Spline(x) + x_residual)
                    final_out_s4(i) <= curve_val_s3(i) + bg_s3(i);
                end if;
            end loop;
        end if;
    end process;

    ----------------------------------------------------------------------------
    -- ВЫХОДНОЙ ПОТОК
    ----------------------------------------------------------------------------
    valid_o <= valid_s4;
    process(final_out_s4)
    begin
        for i in 0 to C_VECTOR_LANES-1 loop
            result_o((i+1)*16 - 1 downto i*16) <= std_logic_vector(final_out_s4(i));
        end loop;
    end process;

end architecture rtl;