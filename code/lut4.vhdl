library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity lut4_core is
    generic (
        C_CLUSTERS    : integer := 32;  -- Количество кластеров на кристалле
        C_LANES_PER_C : integer := 16;  -- Каналов в кластере
        C_DATA_WIDTH  : integer := 8    -- Разрядность данных (INT8)
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Иерархический интерфейс конфигурации LUT4 (16 ячеек: адрес 0..15)
        cfg_we_i        : in  std_logic;
        cfg_cluster_sel : in  std_logic_vector(4 downto 0);
        cfg_addr_i      : in  std_logic_vector(3 downto 0);  -- 4 бита для LUT4
        cfg_data_i      : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
        
        -- Потоковый ввод (4-битные индексы)
        valid_i         : in  std_logic;
        index_in        : in  std_logic_vector((C_CLUSTERS * C_LANES_PER_C * 4) - 1 downto 0);
        
        -- Потоковый вывод
        valid_o         : out std_logic;
        data_out        : out std_logic_vector((C_CLUSTERS * C_LANES_PER_C * C_DATA_WIDTH) - 1 downto 0)
    );
end entity lut4_core;

architecture rtl of lut4_core is

    -- 2^4 = 16 ячеек памяти на каждую таблицу LUT4
    type t_lut_table   is array (0 to 15) of std_logic_vector(C_DATA_WIDTH-1 downto 0);
    type t_cluster_ram is array (0 to C_LANES_PER_C-1) of t_lut_table;
    type t_system_mem  is array (0 to C_CLUSTERS-1) of t_cluster_ram;
    
    signal clusters_mem : t_system_mem;
    signal valid_pipe   : std_logic_vector(2 downto 0);

    type t_cluster_out_arr is array (0 to C_CLUSTERS-1) of std_logic_vector((C_LANES_PER_C * C_DATA_WIDTH) - 1 downto 0);
    signal cluster_res  : t_cluster_out_arr;

begin

    ----------------------------------------------------------------------------
    -- 1. ИЕРАРХИЧЕСКАЯ ЗАПИСЬ КОНФИГУРАЦИИ LUT4
    ----------------------------------------------------------------------------
    process(clk)
        variable v_cluster_idx : integer;
        variable v_addr_idx    : integer;
    begin
        if rising_edge(clk) then
            if cfg_we_i = '1' then
                v_cluster_idx := to_integer(unsigned(cfg_cluster_sel));
                v_addr_idx    := to_integer(unsigned(cfg_addr_i));
                if v_cluster_idx < C_CLUSTERS then
                    for l in 0 to C_LANES_PER_C-1 loop
                        clusters_mem(v_cluster_idx)(l)(v_addr_idx) <= cfg_data_i;
                    end loop;
                end if;
            end if;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- 2. ТРЕХСТУПЕНЧАТЫЙ КОНВЕЙЕР ВЫЧИСЛЕНИЙ LUT4
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_idx : integer range 0 to 15;
        constant C_IN_BITS : integer := 4;
        constant C_CLUSTER_WIDTH : integer := C_LANES_PER_C * C_DATA_WIDTH;
        constant C_IN_CLUSTER_BITS : integer := C_LANES_PER_C * 4;
    begin
        if rst_n = '0' then
            for c in 0 to C_CLUSTERS-1 loop
                cluster_res(c) <= (others => '0');
            end loop;
            valid_pipe <= (others => '0');
            valid_o    <= '0';
        elsif rising_edge(clk) then
            valid_pipe(0) <= valid_i;
            valid_pipe(1) <= valid_pipe(0);
            valid_pipe(2) <= valid_pipe(1);
            valid_o       <= valid_pipe(2);

            for c in 0 to C_CLUSTERS-1 loop
                for l in 0 to C_LANES_PER_C-1 loop
                    -- Извлекаем 4-битный индекс
                    v_idx := to_integer(unsigned(index_in( (c * C_IN_CLUSTER_BITS) + ((l+1)*4 - 1) downto (c * C_IN_CLUSTER_BITS) + (l*4) )));
                    
                    -- Чтение из распределенной памяти LUT4
                    cluster_res(c)((l+1)*C_DATA_WIDTH - 1 downto l*C_DATA_WIDTH) <= clusters_mem(c)(l)(v_idx);
                end loop;
            end loop;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- 3. СБОРКА ВЫХОДНОГО ПОТОКА
    ----------------------------------------------------------------------------
    process(cluster_res)
        constant C_CLUSTER_WIDTH : integer := C_LANES_PER_C * C_DATA_WIDTH;
    begin
        for c in 0 to C_CLUSTERS-1 loop
            data_out((c+1)*C_CLUSTER_WIDTH - 1 downto c*C_CLUSTER_WIDTH) <= cluster_res(c);
        end loop;
    end process;

end architecture rtl;