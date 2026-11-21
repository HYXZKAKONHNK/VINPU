library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package vinpu_arch_pkg is

    ----------------------------------------------------------------------------
    -- 1. КОНФИГУРАЦИЯ ПЛАТФОРМЫ И МАСШТАБИРОВАНИЕ (Full X4 / Lite L2)
    ----------------------------------------------------------------------------
    constant C_DEVICE_ID_X4_AIR   : std_logic_vector(15 downto 0) := x"7024";
    constant C_DEVICE_ID_X4_WATER : std_logic_vector(15 downto 0) := x"7025";
    constant C_DEVICE_ID_L2       : std_logic_vector(15 downto 0) := x"7022";
    constant C_VENDOR_ID          : std_logic_vector(15 downto 0) := x"10EE"; -- Xilinx / Custom Subsystem

    -- Параметры узла (1x Artix-7 XC7A200T + 4x DDR3L x16)
    constant C_PCIE_DATA_WIDTH    : integer := 128; -- AXI4-Stream PCIe Gen2 x4 (125 MHz)
    constant C_DDR_DATA_WIDTH     : integer := 256; -- MIG 4:1 user interface (4x16 = 64-bit phys)
    constant C_AXI_ADDR_WIDTH     : integer := 64;  -- Поддержка >4GB адресного пространства хоста
    constant C_LOCAL_ADDR_WIDTH   : integer := 32;  -- 4 GB локальной DDR3L на одну FPGA

    ----------------------------------------------------------------------------
    -- 2. КАРТА РЕГИСТРОВ BAR0 (MMIO - смещения в байтах)
    ----------------------------------------------------------------------------
    constant REG_MAGIC_VER        : std_logic_vector(11 downto 0) := x"000"; -- [31:16]=0x5649 ("VI"), [15:0]=Ver
    constant REG_NODE_INFO        : std_logic_vector(11 downto 0) := x"004"; -- [3:0]=NodeID (0..3), [7:4]=TotalNodes
    constant REG_CTRL             : std_logic_vector(11 downto 0) := x"008"; -- Bit0: Enable, Bit1: SoftReset, Bit2: IRQ_En
    constant REG_STATUS           : std_logic_vector(11 downto 0) := x"00C"; -- Bit0: Busy, Bit1: DDR_Calib_Done, Bit2: Error
    
    -- Управление кольцевым буфером DMA (Host -> FPGA)
    constant REG_RING_BASE_LO     : std_logic_vector(11 downto 0) := x"010"; -- Физический адрес кольца в RAM хоста (Low)
    constant REG_RING_BASE_HI     : std_logic_vector(11 downto 0) := x"014"; -- Физический адрес кольца в RAM хоста (High)
    constant REG_RING_SIZE        : std_logic_vector(11 downto 0) := x"018"; -- Количество слотов (степень двойки)
    constant REG_RING_HEAD        : std_logic_vector(11 downto 0) := x"01C"; -- Указатель чтения (обновляет FPGA)
    constant REG_RING_TAIL        : std_logic_vector(11 downto 0) := x"020"; -- Doorbell: указатель записи (пишет драйвер)

    -- Канал связи с Allwinner H313 (межчиповый барьер и телеметрия)
    constant REG_H313_SYNC_CTRL   : std_logic_vector(11 downto 0) := x"030"; -- Аппаратный барьер синхронизации 4-х FPGA
    constant REG_TEMP_VOLT        : std_logic_vector(11 downto 0) := x"034"; -- XADC температура кристалла и VCCINT

    -- Счетчики производительности (Hardware Profiling для драйвера)
    constant REG_PERF_CYCLES_LO   : std_logic_vector(11 downto 0) := x"040";
    constant REG_PERF_CYCLES_HI   : std_logic_vector(11 downto 0) := x"044";
    constant REG_PERF_MAC_OPS_LO  : std_logic_vector(11 downto 0) := x"048";
    constant REG_PERF_MAC_OPS_HI  : std_logic_vector(11 downto 0) := x"04C";

    ----------------------------------------------------------------------------
    -- 3. ТИПЫ ДАННЫХ И ОПКОДЫ ВЫЧИСЛИТЕЛЬНОГО ЯДРА
    ----------------------------------------------------------------------------
    subtype t_dtype is std_logic_vector(3 downto 0);
    constant DTYPE_INT2           : t_dtype := x"0";
    constant DTYPE_INT4           : t_dtype := x"1";
    constant DTYPE_INT8           : t_dtype := x"2";
    constant DTYPE_FP16           : t_dtype := x"3";
    constant DTYPE_BF16           : t_dtype := x"4";
    constant DTYPE_FP32           : t_dtype := x"5";
    constant DTYPE_FP64           : t_dtype := x"6";
    constant DTYPE_LUT4           : t_dtype := x"8";
    constant DTYPE_LUT6           : t_dtype := x"9";
    constant DTYPE_LUT8           : t_dtype := x"A";
    constant DTYPE_LUT10          : t_dtype := x"B";
    constant DTYPE_LUT12          : t_dtype := x"C";

    subtype t_opcode is std_logic_vector(7 downto 0);
    constant OP_NOP               : t_opcode := x"00";
    constant OP_DMA_H2D           : t_opcode := x"01"; -- Копирование весов/активаций Host -> DDR3L
    constant OP_DMA_D2H           : t_opcode := x"02"; -- Выгрузка результата DDR3L -> Host
    constant OP_MATMUL            : t_opcode := x"10"; -- Матричное умножение (GEMM)
    constant OP_CONV2D            : t_opcode := x"11"; -- Свертка
    constant OP_SOFTMAX           : t_opcode := x"20"; -- Special Cores (активации/нормализация)
    constant OP_RMSNORM           : t_opcode := x"21";
    constant OP_BARRIER_SYNC      : t_opcode := x"F0"; -- Синхронизация всех 4 FPGA через H313

    ----------------------------------------------------------------------------
    -- 4. СТРУКТУРА АППАРАТНОГО ДЕСКРИПТОРА ЗАДАЧИ (256 бит / 32 байта)
    ----------------------------------------------------------------------------
    type t_cmd_descriptor is record
        opcode      : t_opcode;                      -- [7:0] Код операции
        dtype       : t_dtype;                       -- [11:8] Формат точности
        flags       : std_logic_vector(3 downto 0);  -- [15:12] Bit0: IRQ по завершении, Bit1: Accumulate
        task_id     : std_logic_vector(15 downto 0); -- [31:16] ID задачи для трекинга в драйвере
        src_addr    : std_logic_vector(63 downto 0); -- [95:32] Адрес источника (Host или DDR3L)
        dst_addr    : std_logic_vector(63 downto 0); -- [159:96] Адрес назначения
        weight_addr : std_logic_vector(31 downto 0); -- [191:160] Адрес весов в локальной DDR3L
        dim_m       : std_logic_vector(15 downto 0); -- [207:192] Размерность M (или длина DMA в блоках)
        dim_n       : std_logic_vector(15 downto 0); -- [223:208] Размерность N
        dim_k       : std_logic_vector(15 downto 0); -- [239:224] Размерность K
        sync_mask   : std_logic_vector(15 downto 0); -- [255:240] Маска барьера для H313
    end record;

    -- Функции упаковки/распаковки дескриптора из 256-битной шины AXI
    function unpack_descriptor(raw : std_logic_vector(255 downto 0)) return t_cmd_descriptor;
    function pack_descriptor(desc : t_cmd_descriptor) return std_logic_vector;

    ----------------------------------------------------------------------------
    -- 5. ВНУТРЕННИЕ ПОТОКОВЫЕ ИНТЕРФЕЙСЫ (AXI4-Stream между блоками FPGA)
    ----------------------------------------------------------------------------
    type t_axis_data is record
        tdata  : std_logic_vector(C_DDR_DATA_WIDTH - 1 downto 0);
        tkeep  : std_logic_vector((C_DDR_DATA_WIDTH / 8) - 1 downto 0);
        tvalid : std_logic;
        tlast  : std_logic;
    end record;

end package vinpu_arch_pkg;

package body vinpu_arch_pkg is

    function unpack_descriptor(raw : std_logic_vector(255 downto 0)) return t_cmd_descriptor is
        variable res : t_cmd_descriptor;
    begin
        res.opcode      := raw(7 downto 0);
        res.dtype       := raw(11 downto 8);
        res.flags       := raw(15 downto 12);
        res.task_id     := raw(31 downto 16);
        res.src_addr    := raw(95 downto 32);
        res.dst_addr    := raw(159 downto 96);
        res.weight_addr := raw(191 downto 160);
        res.dim_m       := raw(207 downto 192);
        res.dim_n       := raw(223 downto 208);
        res.dim_k       := raw(239 downto 224);
        res.sync_mask   := raw(255 downto 240);
        return res;
    end function;

    function pack_descriptor(desc : t_cmd_descriptor) return std_logic_vector is
        variable raw : std_logic_vector(255 downto 0);
    begin
        raw(7 downto 0)     := desc.opcode;
        raw(11 downto 8)    := desc.dtype;
        raw(15 downto 12)   := desc.flags;
        raw(31 downto 16)   := desc.task_id;
        raw(95 downto 32)   := desc.src_addr;
        raw(159 downto 96)  := desc.dst_addr;
        raw(191 downto 160) := desc.weight_addr;
        raw(207 downto 192) := desc.dim_m;
        raw(223 downto 208) := desc.dim_n;
        raw(239 downto 224) := desc.dim_k;
        raw(255 downto 240) := desc.sync_mask;
        return raw;
    end function;

end package body vinpu_arch_pkg;