library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity render is
    generic (
        C_SCREEN_WIDTH  : integer := 1920;
        C_SCREEN_HEIGHT : integer := 1080
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Управление фреймбуфером (Сигнал смены кадров / VSync от хоста или таймера)
        frame_swap_i    : in  std_logic;
        
        -- Входные пиксельные фрагменты от pixel_rast.vhdl
        pixel_valid_i   : in  std_logic;
        pixel_x_i       : in  std_logic_vector(15 downto 0);
        pixel_y_i       : in  std_logic_vector(15 downto 0);
        pixel_color_i   : in  std_logic_vector(23 downto 0); -- RGB888
        pixel_alpha_i   : in  std_logic_vector(7 downto 0);  -- Альфа-канал [0..255]

        -- Выходной готовый видеопоток (на экран / в память для анализа ИИ-моделью ViOne)
        stream_valid_o  : out std_logic;
        stream_pixel_o  : out std_logic_vector(31 downto 0); -- ARGB8888
        vsync_o         : out std_logic;
        hsync_o         : out std_logic
    );
end entity render;

architecture rtl of render is

    -- Сигналы блендинга и компоновки
    signal blended_r     : unsigned(7 downto 0);
    signal blended_g     : unsigned(7 downto 0);
    signal blended_b     : unsigned(7 downto 0);
    signal active_pixel  : std_logic_vector(31 downto 0);
    
    -- Синхронизация развертки
    signal h_counter     : unsigned(11 downto 0);
    signal v_counter     : unsigned(11 downto 0);
    signal v_active      : std_logic;
    signal h_active      : std_logic;

begin

    ----------------------------------------------------------------------------
    -- 1. АППАРАТНЫЙ АЛЬФА-БЛЕНДИНГ (ФОРМУЛА OVER: C_out = C_src * alpha + C_bg * (1-alpha))
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_src_r, v_src_g, v_src_b : unsigned(7 downto 0);
        variable v_alpha : unsigned(7 downto 0);
        variable v_res_r, v_res_g, v_res_b : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            blended_r <= (others => '0');
            blended_g <= (others => '0');
            blended_b <= (others => '0');
        elsif rising_edge(clk) then
            if pixel_valid_i = '1' then
                v_src_r := unsigned(pixel_color_i(23 downto 16));
                v_src_g := unsigned(pixel_color_i(15 downto 8));
                v_src_b := unsigned(pixel_color_i(7 downto 0));
                v_alpha := unsigned(pixel_alpha_i);

                -- Аппаратное умножение цвета на альфа-канал (масштабирование 0..255)
                v_res_r := v_src_r * v_alpha;
                v_res_g := v_src_g * v_alpha;
                v_res_b := v_src_b * v_alpha;

                -- Сдвиг на 8 бит (деление на 255 с приближением) и упаковка
                blended_r <= v_res_r(15 downto 8);
                blended_g <= v_res_g(15 downto 8);
                blended_b <= v_res_b(15 downto 8);
            end if;
        end if;
    end process;

    -- Упаковка в 32-битный ARGB пиксель для финишной выдачи
    active_pixel <= x"FF" & std_logic_vector(blended_r) & std_logic_vector(blended_g) & std_logic_vector(blended_b);


    ----------------------------------------------------------------------------
    -- 2. ГЕНЕРАТОР ВИДЕО-ТАЙМИНГОВ И ПОТОКА (Синхронизация кадра)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            h_counter     <= (others => '0');
            v_counter     <= (others => '0');
            stream_valid_o<= '0';
            stream_pixel_o<= (others => '0');
            vsync_o       <= '1';
            hsync_o       <= '1';
        elsif rising_edge(clk) then
            stream_valid_o <= pixel_valid_i;
            stream_pixel_o <= active_pixel;

            -- Стандартный счетчик развертки под 1920x1080 (упрощенная модель синхронизации)
            if h_counter >= 2200 then
                h_counter <= (others => '0');
                if v_counter >= 1125 then
                    v_counter <= (others => '0');
                else
                    v_counter <= v_counter + 1;
                end if;
            else
                h_counter <= h_counter + 1;
            end if;

            -- Импульсы синхронизации
            if h_counter >= 1928 and h_counter < 1968 then
                hsync_o <= '0';
            else
                hsync_o <= '1';
            end if;

            if v_counter >= 1083 and v_counter < 1088 then
                vsync_o <= '0';
            else
                vsync_o <= '1';
            end if;
        end if;
    end process;

end architecture rtl;