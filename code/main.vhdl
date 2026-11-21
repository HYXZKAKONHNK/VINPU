library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use work.vinpu_arch_pkg.all;

entity main is
    generic (
        C_NODE_ID : integer range 0 to 3 := 0 -- Идентификатор FPGA в системе (0..3 для Full X4)
    );
    port (
        -- Системный тактовый сигнал и сброс (от PCIe / тактового генератора платы)
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- AXI4-Lite Slave (Интерфейс для BAR0 MMIO от хоста)
        s_axil_awaddr   : in  std_logic_vector(11 downto 0);
        s_axil_awvalid  : in  std_logic;
        s_axil_awready  : out std_logic;
        s_axil_wdata    : in  std_logic_vector(31 downto 0);
        s_axil_wstrb    : in  std_logic_vector(3. downto 0);
        s_axil_wvalid   : in  std_logic;
        s_axil_wready   : out std_logic;
        s_axil_bresp    : out std_logic_vector(1 downto 0);
        s_axil_bvalid   : out std_logic;
        s_axil_bready   : in  std_logic;
        s_axil_araddr   : in  std_logic_vector(11 downto 0);
        s_axil_arvalid  : in  std_logic;
        s_axil_arready  : out std_logic;
        s_axil_rdata    : out std_logic_vector(31 downto 0);
        s_axil_rresp    : out std_logic_vector(1 downto 0);
        s_axil_rvalid   : out std_logic;
        s_axil_rready   : in  std_logic;

        -- AXI4 Master (Интерфейс для чтения дескрипторов из RAM хоста и обмена с DDR3L)
        m_axi_araddr    : out std_logic_vector(63 downto 0);
        m_axi_arlen     : out std_logic_vector(7 downto 0);
        m_axi_arvalid   : out std_logic;
        m_axi_arready   : in  std_logic;
        m_axi_rdata     : in  std_logic_vector(127 downto 0);
        m_axi_rresp     : in  std_logic_vector(1 downto 0);
        m_axi_rlast     : in  std_logic;
        m_axi_rvalid    : in  std_logic;
        m_axi_rready    : out std_logic;

        -- Прерывание к хосту (MSI / IRQ)
        irq_o           : out std_logic;

        -- Шина управления локальными вычислительными ядрами и DDR3L
        exec_start_o    : out std_logic;
        exec_busy_i     : in  std_logic;
        exec_opcode_o   : out t_opcode;
        exec_dtype_o    : out t_dtype;
        exec_desc_o     : out t_cmd_descriptor
    );
end entity main;

architecture rtl of main is

    -- Регистровый файл BAR0
    signal reg_ctrl_en      : std_logic;
    signal reg_ctrl_reset   : std_logic;
    signal reg_ctrl_irq_en  : std_logic;
    signal reg_status_busy  : std_logic;
    signal reg_status_ddr   : std_logic;
    
    signal reg_ring_base_lo : std_logic_vector(31 downto 0);
    signal reg_ring_base_hi : std_logic_vector(31 downto 0);
    signal reg_ring_size    : std_logic_vector(31 downto 0);
    signal reg_ring_head    : std_logic_vector(31 downto 0);
    signal reg_ring_tail    : std_logic_vector(31 downto 0);
    signal reg_h313_sync    : std_logic_vector(31 downto 0);

    -- Автомат состояний диспетчера
    type t_dispatcher_state is (ST_IDLE, ST_FETCH_REQ, ST_FETCH_WAIT, ST_DECODE_EXEC, ST_WAIT_EXEC, ST_UPDATE_HEAD);
    signal state : t_dispatcher_state;

    -- Буфер принятого дескриптора (256 бит = 32 байта)
    signal raw_descriptor : std_logic_vector(255 downto 0);
    signal desc_buffer    : t_cmd_descriptor;
    signal fetch_word_cnt : integer range 0 to 3;

    -- Внутренние сигналы квитирования AXI-Lite
    signal axil_awready_i   : std_logic;
    signal axil_wready_i    : std_logic;
    signal axil_bvalid_i    : std_logic;
    signal axil_arready_i   : std_logic;
    signal axil_rvalid_i    : std_logic;
    signal axil_rdata_i     : std_logic_vector(31 downto 0);

begin

    s_axil_awready <= axil_awready_i;
    s_axil_wready  <= axil_wready_i;
    s_axil_bvalid  <= axil_bvalid_i;
    s_axil_arready <= axil_arready_i;
    s_axil_rvalid  <= axil_rvalid_i;
    s_axil_rdata   :  = axil_rdata_i;
    s_axil_bresp   <= "00"; -- OKAY
    s_axil_rresp   <= "00"; -- OKAY

    ----------------------------------------------------------------------------
    -- 1. ЛОГИКА AXI4-LITE SLAVE (КАРТА РЕГИСТРОВ BAR0)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            axil_awready_i   <= '1';
            axil_wready_i    <= '1';
            axil_bvalid_i    <= '0';
            axil_arready_i   <= '1';
            axil_rvalid_i    <= '0';
            axil_rdata_i     <= (others => '0');

            reg_ctrl_en      <= '0';
            reg_ctrl_reset   <= '0';
            reg_ctrl_irq_en  <= '0';
            reg_ring_base_lo <= (others => '0');
            reg_ring_base_hi <= (others => '0');
            reg_ring_size    :  = x"00000020"; -- По умолчанию 32 слота
            reg_ring_tail    <= (others => '0');
            reg_h313_sync    <= (others => '0');
            reg_status_ddr   <= '1'; -- Считаем DDR откалиброванной по умолчанию
        elsif rising_edge(clk) then
            -- Базовый сброс сигналов ответа
            if axil_bvalid_i = '1' and s_axil_bready = '1' then
                axil_bvalid_i <= '0';
            end if;
            if axil_rvalid_i = '1' and s_axil_rready = '1' then
                axil_rvalid_i <= '0';
            end if;

            -- Обработка записи из Windows-драйвера
            if axil_awready_i = '1' and s_axil_awvalid = '1' and axil_wready_i = '1' and s_axil_wvalid = '1' then
                axil_awready_i <= '0';
                axil_wready_i  <= '0';
                axil_bvalid_i  <= '1';

                case s_axil_awaddr(11 downto 0) is
                    when REG_CTRL =>
                        reg_ctrl_en    <= s_axil_wdata(0);
                        reg_ctrl_reset <= s_axil_wdata(1);
                        reg_ctrl_irq_en<= s_axil_wdata(2);
                    when REG_RING_BASE_LO =>
                        reg_ring_base_lo <= s_axil_wdata;
                    when REG_RING_BASE_HI =>
                        reg_ring_base_hi <= s_axil_wdata;
                    when REG_RING_SIZE =>
                        reg_ring_size    <= s_axil_wdata;
                    when REG_RING_TAIL =>
                        reg_ring_tail    <= s_axil_wdata; -- Doorbell от драйвера
                    when REG_H313_SYNC_CTRL =>
                        reg_h313_sync    <= s_axil_wdata;
                    when others =>
                        null;
                end case;
            else
                axil_awready_i <= '1';
                axil_wready_i  <= '1';
            end if;

            -- Обработка чтения из Windows-драйвера
            if axil_arready_i = '1' and s_axil_arvalid = '1' then
                axil_arready_i <= '0';
                axil_rvalid_i  <= '1';

                case s_axil_araddr(11 downto 0) is
                    when REG_MAGIC_VER =>
                        axil_rdata_i <= x"56490001"; -- "VI" + Версия 1
                    when REG_NODE_INFO =>
                        axil_rdata_i <= x"000000" & "0" & std_logic_vector(to_unsigned(C_NODE_ID, 3));
                    when REG_CTRL =>
                        axil_rdata_i <= x"000000" & "00000" & reg_ctrl_irq_en & reg_ctrl_reset & reg_ctrl_en;
                    when REG_STATUS =>
                        axil_rdata_i <= x"000000" & "00" & reg_status_ddr & reg_status_busy;
                    when REG_RING_BASE_LO =>
                        axil_rdata_i <= reg_ring_base_lo;
                    when REG_RING_BASE_HI =>
                        axil_rdata_i <= reg_ring_base_hi;
                    when REG_RING_SIZE =>
                        axil_rdata_i <= reg_ring_size;
                    when REG_RING_HEAD =>
                        axil_rdata_i <= reg_ring_head;
                    when REG_RING_TAIL =>
                        axil_rdata_i <= reg_ring_tail;
                    when REG_H313_SYNC_CTRL =>
                        axil_rdata_i <= reg_h313_sync;
                    when others =>
                        axil_rdata_i <= (others => '0');
                end case;
            else
                axil_arready_i <= '1';
            end if;

            -- Аппаратное инкрементирование HEAD обновляется в автомате диспетчера
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- 2. КОНЕЧНЫЙ АВТОМАТ ДИСПЕТЧЕРА ДЕСКРИПТОРОВ (FETCH & EXECUTE)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_current_tail : unsigned(31 downto 0);
        variable v_current_head : unsigned(31 downto 0);
        variable v_desc_byte_offset : unsigned(63 downto 0);
    begin
        if rst_n = '0' then
            state          <= ST_IDLE;
            reg_ring_head  <= (others => '0');
            reg_status_busy<= '0';
            m_axi_arvalid  <= '0';
            m_axi_araddr   <= (others => '0');
            m_axi_arlen    <= (others => '0');
            m_axi_rready   <= '0';
            exec_start_o   <= '0';
            irq_o          <= '0';
            fetch_word_cnt <= 0;
            raw_descriptor <= (others => '0');
        elsif rising_edge(clk) then
            -- По умолчанию сбрасываем импульсы запуска
            exec_start_o <= '0';
            irq_o        <= '0';

            case state is
                when ST_IDLE =>
                    reg_status_busy <= '0';
                    if reg_ctrl_en = '1' then
                        -- Проверяем кольцевой буфер: если HEAD != TAIL, появились новые задачи
                        if reg_ring_head /= reg_ring_tail then
                            state <= ST_FETCH_REQ;
                            reg_status_busy <= '1';
                        end if;
                    end if;

                when ST_FETCH_REQ =>
                    -- Вычисляем адрес дескриптора в RAM хоста: Base + (Head * 32 байта)
                    v_current_head := unsigned(reg_ring_head);
                    v_desc_byte_offset := shift_left(resize(v_current_head, 64), 5); -- умножение на 32
                    m_axi_araddr  <= resize(unsigned(reg_ring_base_hi), 64) & unsigned(reg_ring_base_lo) + v_desc_byte_offset;
                    m_axi_arlen   <= x"01"; -- Читаем 2 такта по 128 бит (в сумме 256 бит = 32 байта)
                    m_axi_arvalid <= '1';
                    fetch_word_cnt<= 0;
                    state         <= ST_FETCH_WAIT;

                when ST_FETCH_WAIT =>
                    if m_axi_arready = '1' then
                        m_axi_arvalid <= '0';
                    end if;

                    m_axi_rready <= '1';
                    if m_axi_rvalid = '1' then
                        if fetch_word_cnt = 0 then
                            raw_descriptor(127 downto 0) <= m_axi_rdata;
                            fetch_word_cnt <= 1;
                        elsif fetch_word_cnt = 1 then
                            raw_descriptor(255 downto 128) <= m_axi_rdata;
                            m_axi_rready <= '0';
                            state <= ST_DECODE_EXEC;
                        end if;
                    end if;

                when ST_DECODE_EXEC =>
                    -- Распаковываем дескриптор и передаем в вычислительное ядро
                    desc_buffer   <= unpack_descriptor(raw_descriptor);
                    exec_opcode_o <= raw_descriptor(7 downto 0);
                    exec_dtype_o  <= raw_descriptor(11 downto 8);
                    exec_desc_o   <= unpack_descriptor(raw_descriptor);
                    exec_start_o  <= '1'; -- Запуск выполнения
                    state         <= ST_WAIT_EXEC;

                when ST_WAIT_EXEC =>
                    -- Ждем завершения работы вычислительного конвейера
                    if exec_busy_i = '0' then
                        state <= ST_UPDATE_HEAD;
                    end if;

                when ST_UPDATE_HEAD =>
                    -- Инкрементируем HEAD кольцевого буфера по кольцу (с учетом размера буфера)
                    v_current_head := unsigned(reg_ring_head);
                    if v_current_head + 1 >= unsigned(reg_ring_size) then
                        reg_ring_head <= (others => '0');
                    else
                        reg_ring_head <= std_logic_vector(v_current_head + 1);
                    end if;

                    -- Генерируем прерывание хосту, если разрешено в контроллере
                    if reg_ctrl_irq_en = '1' then
                        irq_o <= '1';
                    end if;

                    state <= ST_IDLE;

                when others =>
                    state <= ST_IDLE;
            end case;
        end if;
    end process;

end architecture rtl;