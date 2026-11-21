library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity ddr_arbiter is
    generic (
        C_ADDR_WIDTH : integer := 32;
        C_DATA_WIDTH : integer := 256 -- Шина данных под 4 чипа DDR3L x16 (64-бит физ. * 4 префетч / сериализация)
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- МАСТЕР 0: DMA Engine (Приоритет загрузки весов)
        m0_araddr       : in  std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        m0_arlen        : in  std_logic_vector(7 downto 0);
        m0_arvalid      : in  std_logic;
        m0_arready      : out std_logic;
        m0_rdata        : out std_logic_vector(C_DATA_WIDTH-1 downto 0);
        m0_rresp        : out std_logic_vector(1 downto 0);
        m0_rlast        : out std_logic;
        m0_rvalid       : out std_logic;
        m0_rready       : in  std_logic;

        m0_awaddr       : in  std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        m0_awlen        : in  std_logic_vector(7 downto 0);
        m0_awvalid      : in  std_logic;
        m0_awready      : out std_logic;
        m0_wdata        : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
        m0_wstrb        : in  std_logic_vector((C_DATA_WIDTH/8)-1 downto 0);
        m0_wlast        : in  std_logic;
        m0_wvalid       : in  std_logic;
        m0_wready       : out std_logic;
        m0_bresp        : out std_logic_vector(1 downto 0);
        m0_bvalid       : out std_logic;
        m0_bready       : in  std_logic;

        -- МАСТЕР 1: Вычислительное ядро / Systolic Array (Потоковое чтение весов)
        m1_araddr       : in  std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        m1_arlen        : in  std_logic_vector(7 downto 0);
        m1_arvalid      : in  std_logic;
        m1_arready      : out std_logic;
        m1_rdata        : out std_logic_vector(C_DATA_WIDTH-1 downto 0);
        m1_rresp        : out std_logic_vector(1 downto 0);
        m1_rlast        : out std_logic;
        m1_rvalid       : out std_logic;
        m1_rready       : in  std_logic;

        m1_awaddr       : in  std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        m1_awlen        : in  std_logic_vector(7 downto 0);
        m1_awvalid      : in  std_logic;
        m1_awready      : out std_logic;
        m1_wdata        : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
        m1_wstrb        : in  std_logic_vector((C_DATA_WIDTH/8)-1 downto 0);
        m1_wlast        : in  std_logic;
        m1_wvalid       : in  std_logic;
        m1_wready       : out std_logic;
        m1_bresp        : out std_logic_vector(1 downto 0);
        m1_bvalid       : out std_logic;
        m1_bready       : in  std_logic;

        -- СЛЕЙВ: Выход на контроллер DDR3L MIG (Xilinx Memory Interface)
        s_araddr        : out std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        s_arlen         : out std_logic_vector(7 downto 0);
        s_arvalid       : out std_logic;
        s_arready       : in  std_logic;
        s_rdata         : in  std_logic_vector(C_DATA_WIDTH-1 downto 0);
        s_rresp         : in  std_logic_vector(1 downto 0);
        s_rlast         : in  std_logic;
        s_rvalid        : in  std_logic;
        s_rready        : out std_logic;

        s_awaddr        : out std_logic_vector(C_ADDR_WIDTH-1 downto 0);
        s_awlen         : out std_logic_vector(7 downto 0);
        s_awvalid       : out std_logic;
        s_awready       : in  std_logic;
        s_wdata         : out std_logic_vector(C_DATA_WIDTH-1 downto 0);
        s_wstrb         : out std_logic_vector((C_DATA_WIDTH/8)-1 downto 0);
        s_wlast         : out std_logic;
        s_wvalid        : out std_logic;
        s_wready        : in  std_logic;
        s_bresp         : in  std_logic_vector(1 downto 0);
        s_bvalid        : in  std_logic;
        s_bready        : out std_logic
    );
end entity ddr_arbiter;

architecture rtl of ddr_arbiter

    -- Состояния арбитра для чтения (AR) и записи (AW)
    type t_arb_state is (ST_IDLE, ST_SERVING_M0, ST_SERVING_M1);
    signal rd_state : t_arb_state;
    signal wr_state : t_arb_state;

    -- Внутренние счетчики для отслеживания завершения AXI-берстов по сигналу RLAST / WLAST
    signal rd_beat_cnt : unsigned(7 downto 0);

begin

    ----------------------------------------------------------------------------
    -- 1. АРБИТРАЖ КАНАЛА ЧТЕНИЯ (AR / R)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            rd_state      <= ST_IDLE;
            s_araddr      <= (others => '0');
            s_arlen       <= (others => '0');
            s_arvalid     <= '0';
            m0_arready    <= '0';
            m1_arready    <= '0';
            s_rready      <= '0';
            m0_rdata      <= (others => '0');
            m0_rresp      <= (others => '0');
            m0_rlast      <= '0';
            m0_rvalid     <= '0';
            m1_rdata      <= (others => '0');
            m1_rresp      <= (others => '0');
            m1_rlast      <= '0';
            m1_rvalid     <= '0';
        elsif rising_edge(clk) then
            case rd_state is
                when ST_IDLE =>
                    s_arvalid  <= '0';
                    m0_arready <= '0';
                    m1_arready <= '0';

                    -- Приоритет отдаем Мастеру 0 (DMA), затем Мастеру 1 (Compute Engine)
                    if m0_arvalid = '1' then
                        s_araddr   <= m0_araddr;
                        s_arlen    <= m0_arlen;
                        s_arvalid  <= '1';
                        m0_arready <= s_arready;
                        rd_state   <= ST_SERVING_M0;
                    elsif m1_arvalid = '1' then
                        s_araddr   <= m1_araddr;
                        s_arlen    <= m1_arlen;
                        s_arvalid  <= '1';
                        m1_arready <= s_arready;
                        rd_state   <= ST_SERVING_M1;
                    end if;

                when ST_SERVING_M0 =>
                    s_arready  <= s_arready;
                    if s_arvalid = '1' and s_arready = '1' then
                        s_arvalid <= '0';
                        m0_arready <= '1';
                    end if;

                    -- Проксируем канал данных от памяти к Мастеру 0
                    s_rready  <= m0_rready;
                    m0_rdata  <= s_rdata;
                    m0_rresp  <= s_rresp;
                    m0_rlast  <= s_rlast;
                    m0_rvalid <= s_rvalid;

                    -- Возврат в IDLE по завершении берста (когда пришел rlast и валиден)
                    if s_rvalid = '1' and s_rlast = '1' then
                        rd_state <= ST_IDLE;
                        m0_arready <= '0';
                    end if;

                when ST_SERVING_M1 =>
                    s_arready  <= s_arready;
                    if s_arvalid = '1' and s_arready = '1' then
                        s_arvalid <= '0';
                        m1_arready <= '1';
                    end if;

                    -- Проксируем канал данных от памяти к Мастеру 1
                    s_rready  <= m1_rready;
                    m1_rdata  <= s_rdata;
                    m1_rresp  <= s_rresp;
                    m1_rlast  <= s_rlast;
                    m1_rvalid <= s_rvalid;

                    if s_rvalid = '1' and s_rlast = '1' then
                        rd_state <= ST_IDLE;
                        m1_arready <= '0';
                    end if;

                when others =>
                    rd_state <= ST_IDLE;
            end case;
        end if;
    end process;


    ----------------------------------------------------------------------------
    -- 2. АРБИТРАЖ КАНАЛА ЗАПИСИ (AW / W / B)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            wr_state      <= ST_IDLE;
            s_awaddr      <= (others => '0');
            s_awlen       <= (others => '0');
            s_awvalid     <= '0';
            m0_awready    <= '0';
            m1_awready    <= '0';
            s_wdata       <= (others => '0');
            s_wstrb       <= (others => '0');
            s_wlast       <= '0';
            s_wvalid      <= '0';
            m0_wready     <= '0';
            m1_wready     <= '0';
            m0_bresp      <= (others => '0');
            m0_bvalid     <= '0';
            m1_bresp      <= (others => '0');
            m1_bvalid     <= '0';
            s_bready      <= '0';
        elsif rising_edge(clk) then
            case wr_state is
                when ST_IDLE =>
                    s_awvalid  <= '0';
                    s_wvalid   <= '0';
                    m0_awready <= '0';
                    m1_awready <= '0';
                    m0_wready  <= '0';
                    m1_wready  <= '0';

                    if m0_awvalid = '1' then
                        s_awaddr   <= m0_awaddr;
                        s_awlen    <= m0_awlen;
                        s_awvalid  <= '1';
                        m0_awready <= s_awready;
                        s_wdata    <= m0_wdata;
                        s_wstrb    <= m0_wstrb;
                        s_wlast    <= m0_wlast;
                        s_wvalid   <= m0_wvalid;
                        m0_wready  <= s_wready;
                        wr_state   <= ST_SERVING_M0;
                    elsif m1_awvalid = '1' then
                        s_awaddr   <= m1_awaddr;
                        s_awlen    <= m1_awlen;
                        s_awvalid  <= '1';
                        m1_awready <= s_awready;
                        s_wdata    <= m1_wdata;
                        s_wstrb    <= m1_wstrb;
                        s_wlast    <= m1_wlast;
                        s_wvalid   <= m1_wvalid;
                        m1_wready  <= s_wready;
                        wr_state   <= ST_SERVING_M1;
                    end if;

                when ST_SERVING_M0 =>
                    if s_awvalid = '1' and s_awready = '1' then
                        s_awvalid <= '0';
                    end if;
                    if s_wvalid = '1' and s_wready = '1' then
                        s_wvalid <= '0';
                    end if;

                    s_wdata   <= m0_wdata;
                    s_wstrb   <= m0_wstrb;
                    s_wlast   <= m0_wlast;
                    s_wvalid  <= m0_wvalid;
                    m0_wready <= s_wready;

                    s_bready  <= m0_bready;
                    m0_bresp  <= s_bresp;
                    m0_bvalid <= s_bvalid;

                    if s_bvalid = '1' and m0_bready = '1' then
                        wr_state   <= ST_IDLE;
                        m0_awready <= '0';
                    end if;

                when ST_SERVING_M1 =>
                    if s_awvalid = '1' and s_awready = '1' then
                        s_awvalid <= '0';
                    end if;
                    if s_wvalid = '1' and s_wready = '1' then
                        s_wvalid <= '0';
                    end if;

                    s_wdata   <= m1_wdata;
                    s_wstrb   <= m1_wstrb;
                    s_wlast   <= m1_wlast;
                    s_wvalid  <= m1_wvalid;
                    m1_wready <= s_wready;

                    s_bready  <= m1_bready;
                    m1_bresp  <= s_bresp;
                    m1_bvalid <= s_bvalid;

                    if s_bvalid = '1' and m1_bready = '1' then
                        wr_state   <= ST_IDLE;
                        m1_awready <= '0';
                    end if;

                when others =>
                    wr_state <= ST_IDLE;
            end case;
        end if;
    end process;

end architecture rtl;