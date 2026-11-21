library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.vinpu_arch_pkg.all;

entity app is
    port (
        -- Системные сигналы
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- Хост-интерфейс BAR0 (от Allwinner H313 через PCIe-свитч)
        bar0_addr       : in  std_logic_vector(31 downto 0);
        bar0_wr_en      : in  std_logic;
        bar0_rd_en      : in  std_logic;
        bar0_wdata      : in  std_logic_vector(31 downto 0);
        bar0_rdata      : out std_logic_vector(31 downto 0);
        bar0_ack        : out std_logic;
        
        -- Интерфейс к DDR3L Арбитру (128-битная шина данных)
        ddr_addr_a      : out std_logic_vector(31 downto 0);
        ddr_addr_b      : out std_logic_vector(31 downto 0);
        ddr_addr_c      : out std_logic_vector(31 downto 0);
        ddr_rd_en       : out std_logic;
        ddr_wr_en       : out std_logic;
        ddr_data_in     : in  std_logic_vector(127 downto 0);
        ddr_data_out    : out std_logic_vector(127 downto 0);
        ddr_busy        : in  std_logic;
        
        -- Аппаратное прерывание хосту
        vinpu_irq       : out std_logic
    );
end entity app;

architecture structural of app is

    -- Управляющие сигналы для numpy_accelerator / tensor_core
    signal np_cmd_valid      : std_logic;
    signal np_cmd_opcode     : std_logic_vector(3 downto 0);
    signal np_precision_mode : std_logic_vector(1 downto 0);
    signal np_dim_m          : std_logic_vector(15 downto 0);
    signal np_dim_n          : std_logic_vector(15 downto 0);
    signal np_dim_k          : std_logic_vector(15 downto 0);
    signal np_scale_factor   : std_logic_vector(31 downto 0);
    signal np_cmd_ready      : std_logic;
    signal np_done           : std_logic;

    -- Внутренний регистровый файл конфигурации
    signal reg_control       : std_logic_vector(31 downto 0);

begin

    -- Инстанциация аппаратного NumPy-ускорителя (внутри которого завязаны тензорные ядра)
    u_numpy_acc : entity work.numpy_accelerator
        port map (
            clk            => clk,
            rst_n          => rst_n,
            cmd_valid      => np_cmd_valid,
            cmd_opcode     => np_cmd_opcode,
            precision_mode => np_precision_mode,
            dim_m          => np_dim_m,
            dim_n          => np_dim_n,
            dim_k          => np_dim_k,
            scale_factor   => np_scale_factor,
            cmd_ready      => np_cmd_ready,
            mem_addr_a     => ddr_addr_a,
            mem_addr_b     => ddr_addr_b,
            mem_addr_c     => ddr_addr_c,
            mem_rd_en      => ddr_rd_en,
            mem_wr_en      => ddr_wr_en,
            mem_data_in    => ddr_data_in,
            mem_data_out   => ddr_data_out,
            mem_busy       => ddr_busy,
            done           => np_done
        );

    -- Декодер шины BAR0 для управления из SoC Allwinner H313
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            reg_control       <= (others => '0');
            np_cmd_valid      <= '0';
            np_cmd_opcode     <= (others => '0');
            np_precision_mode <= (others => '0');
            np_dim_m          <= (others => '0');
            np_dim_n          <= (others => '0');
            np_dim_k          <= (others => '0');
            np_scale_factor   <= (others => '0');
            bar0_ack          <= '0';
            bar0_rdata        <= (others => '0');
        elsif rising_edge(clk) then
            bar0_ack     <= '0';
            np_cmd_valid <= '0'; -- Импульсный запуск
            
            -- Запись по шине BAR0 (Memory-Mapped I/O)
            if bar0_wr_en = '1' then
                bar0_ack <= '1';
                case bar0_addr(11 downto 0) is
                    when x"000" => reg_control       <= bar0_wdata;
                    when x"004" => np_cmd_opcode     <= bar0_wdata(3 downto 0);
                                   np_precision_mode <= bar0_wdata(5 downto 4);
                                   np_cmd_valid      <= bar0_wdata(31); -- Старший бит — пуск
                    when x"008" => np_dim_m          <= bar0_wdata(15 downto 0);
                                   np_dim_n          <= bar0_wdata(31 downto 16);
                    when x"00C" => np_dim_k          <= bar0_wdata(15 downto 0);
                    when x"010" => np_scale_factor   <= bar0_wdata;
                    when others => null;
                end case;
            end if;
            
            -- Чтение по шине BAR0
            if bar0_rd_en = '1' then
                bar0_ack <= '1';
                case bar0_addr(11 downto 0) is
                    when x"000" => bar0_rdata <= reg_control;
                    when x"004" => bar0_rdata <= x"000000" & "000" & np_cmd_ready & np_precision_mode & np_cmd_opcode;
                    when x"008" => bar0_rdata <= np_dim_n & np_dim_m;
                    when x"010" => bar0_rdata <= np_scale_factor;
                    when x"014" => bar0_rdata <= (31 downto 1 => '0') & np_done; -- Статус готовности
                    when others => bar0_rdata <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    -- Прерывание по завершению вычислений
    vinpu_irq <= np_done;

end architecture structural;