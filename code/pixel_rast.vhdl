library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity pixel_rasterizer is
    generic (
        C_SCREEN_WIDTH  : integer := 1920;
        C_SCREEN_HEIGHT : integer := 1080;
        C_PIXEL_LANES   : integer := 4     -- Квад-пайплайн параллельной генерации пикселей
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Входные потоковые данные от SVG / Geometry Engine
        valid_i         : in  std_logic;
        coord_x_i       : in  std_logic_vector(15 downto 0); -- Экранная координата X
        coord_y_i       : in  std_logic_vector(15 downto 0); -- Экранная координата Y
        coverage_i      : in  std_logic_vector(7 downto 0);  -- Субпиксельное покрытие / Alpha [0..255]
        color_in_i      : in  std_logic_vector(23 downto 0); -- Базовый RGB888 цвет примитива

        -- Потоковый выход пиксельных фрагментов для модуля render.vhdl
        valid_o         : out std_logic;
        pixel_x_o       : out std_logic_vector(15 downto 0);
        pixel_y_o       : out std_logic_vector(15 downto 0);
        pixel_color_o   : out std_logic_vector(23 downto 0);
        pixel_alpha_o   : out std_logic_vector(7 downto 0)
    );
end entity pixel_rasterizer;

architecture rtl of pixel_rasterizer is

    -- Конвейерные регистры фильтрации растра и отсечения по экрану (Scissor Test / Viewport)
    signal valid_pipe    : std_logic_vector(3 downto 0);
    signal x_pipe        : std_logic_vector(15 downto 0);
    signal y_pipe        : std_logic_vector(15 downto 0);
    signal color_pipe    : std_logic_vector(23 downto 0);
    signal alpha_pipe    : std_logic_vector(7 downto 0);

begin

    ----------------------------------------------------------------------------
    -- 4-СТУПЕНЧАТЫЙ КОНВЕЙЕР РАСТЕРИЗАЦИИ И СУБПИКСЕЛЬНОГО СМЕШИВАНИЯ
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_x : unsigned(15 downto 0);
        variable v_y : unsigned(15 downto 0);
        variable v_in_screen : boolean;
    begin
        if rst_n = '0' then
            valid_pipe    <= (others => '0');
            x_pipe        <= (others => '0');
            y_pipe        <= (others => '0');
            color_pipe    <= (others => '0');
            alpha_pipe    <= (others => '0');
            valid_o       <= '0';
            pixel_x_o     <= (others => '0');
            pixel_y_o     <= (others => '0');
            pixel_color_o <= (others => '0');
            pixel_alpha_o <= (others => '0');
        elsif rising_edge(clk) then
            -- Сдвиговый регистр валидности потока пикселей
            valid_pipe(0) <= valid_i;
            valid_pipe(1) <= valid_pipe(0);
            valid_pipe(2) <= valid_pipe(1);
            valid_pipe(3) <= valid_pipe(2);
            valid_o       <= valid_pipe(3);

            -- Ступень 1-2: Проверка попадания в физический viewport экрана
            if valid_i = '1' then
                v_x := unsigned(coord_x_i);
                v_y := unsigned(coord_y_i);
                
                -- Аппаратный Scissor Test: отсекаем пиксели за пределами экрана
                if v_x < C_SCREEN_WIDTH and v_y < C_SCREEN_HEIGHT then
                    x_pipe     <= coord_x_i;
                    y_pipe     <= coord_y_i;
                    color_pipe <= color_in_i;
                    alpha_pipe <= coverage_i;
                else
                    -- Зануляем альфу для пикселей вне экрана (отбрасывание)
                    alpha_pipe <= (others => '0');
                end if;
            end if;

            -- Ступень 3-4: Выдача фрагмента в финальный буфер рендерера
            pixel_x_o     <= x_pipe;
            pixel_y_o     <= y_pipe;
            pixel_color_o <= color_pipe;
            pixel_alpha_o <= alpha_pipe;
        end if;
    end process;

end architecture rtl;