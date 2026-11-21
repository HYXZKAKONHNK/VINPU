library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity lut6_core is
    generic (
        C_LANES       : integer := 8;  -- Количество параллельных каналов LUT в ядре
        C_DATA_WIDTH  : integer := 8   -- Разрядность выходного значения (например, INT8 для активаций)
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        
        -- Интерфейс конфигурации таблицы (загрузка кривой активации / квантования от хоста)
        cfg_we        : in  std_logic;
        cfg_addr      : in  std_logic_vector(5 downto 0); -- 6-битный адрес (64 ячейки для LUT6)
        cfg_data      : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
        
        -- Потоковый ввод (вектор 6-битных индексов / квантованных входных значений)
        valid_i       : in  std_logic;
        data_in       : in  std_logic_vector((C_LANES * 6) - 1 downto 0);
        
        -- Потоковый вывод результатов после применения LUT
        valid_o       : out std_logic;
        data_out      : out std_logic_vector((C_LANES * C_DATA_WIDTH) - 1 downto 0)
    );
end entity lut6_core;

architecture rtl of lut6_core is

    -- Память распределенной логики (Distributed RAM / ROM) для LUT6
    -- Каждая таблица содержит 64 ячейки (2^6) заданной разрядности
    type t_lut_table is array (0 to 63) of std_logic_vector(C_DATA_WIDTH-1 downto 0);
    type t_lut_array is array (0 to C_LANES-1) of t_lut_table;
    
    signal lut_mem : t_lut_array;

    -- Конвейерные регистры для обеспечения высокой тактовой частоты (Fmax)
    signal valid_pipe : std_logic_vector(1 downto 0);
    type t_out_array is array (0 to C_LANES-1) of std_logic_vector(C_DATA_WIDTH-1 downto 0);
    signal stage_out  : t_out_array;

begin

    ----------------------------------------------------------------------------
    -- 1. ЛОГИКА КОНФИГУРАЦИИ И ЧТЕНИЯ (Distributed RAM с синхронной записью)
    ----------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            -- Запись новых коэффициентов LUT хостом (например, таблица Swish/GELU)
            if cfg_we = '1' then
                for i in 0 to C_LANES-1 loop
                    lut_mem(i)(to_integer(unsigned(cfg_addr))) <= cfg_data;
                end loop;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- 2. ПАРАЛЛЕЛЬНОЕ ВЫЧИСЛЕНИЕ (LOOKUP) И КОНВЕЙЕРИЗАЦИЯ
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_idx : integer range 0 to 63;
    begin
        if rst_n = '0' then
            for i in 0 to C_LANES-1 loop
                stage_out(i) <= (others => '0');
            end loop;
            valid_pipe   <= (others => '0');
            valid_o      <= '0';
        elsif rising_edge(clk) then
            -- Сдвиговый регистр валидности данных для конвейера
            valid_pipe(0) <= valid_i;
            valid_pipe(1) <= valid_pipe(0);
            valid_o       <= valid_pipe(1);

            -- Параллельный обход всех каналов LUT
            for i in 0 to C_LANES-1 loop
                -- Извлекаем 6-битный индекс для конкретного канала
                v_idx := to_integer(unsigned(data_in((i+1)*6 - 1 downto i*6)));
                -- Читаем значение из распределенной памяти LUT6
                stage_out(i) <= lut_mem(i)(v_idx);
            end loop;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- 3. СБОРКА ВЫХОДНОГО ПАКЕТНОГО ВЕКТОРА
    ----------------------------------------------------------------------------
    process(stage_out)
    begin
        for i in 0 to C_LANES-1 loop
            data_out((i+1)*C_DATA_WIDTH - 1 downto i*C_DATA_WIDTH) <= stage_out(i);
        end loop;
    end process;

end architecture rtl;