library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity x64_core is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Входной поток байт x86_64 инструкции (до 8 байт за такт: префикс + опкод + ModR/M + непосредственное значение)
        instruction_i   : in  std_logic_vector(63 downto 0);
        valid_i         : in  std_logic;
        ready_o         : out std_logic;

        -- Выход декодированных 64-битных микроопераций (µops) на конвейер ViNPU / ALU
        uop_valid_o     : out std_logic;
        uop_type_o      : out std_logic_vector(3 downto 0);  -- Тип операции (MOV, ADD, SUB, CMP, JMP)
        uop_rex_w_o     : out std_logic;                     -- '1' = 64-битный операнд (REX.W), '0' = 32-битный
        uop_reg_dest_o  : out std_logic_vector(3 downto 0);  -- Целевой регистр (0..15 с учетом REX.R/B)
        uop_reg_src_o   : out std_logic_vector(3 downto 0);  -- Исходный регистр (0..15)
        uop_imm_o       : out std_logic_vector(63 downto 0)  -- 64-битное непосредственное значение / смещение
    );
end entity x64_core;

architecture rtl of x64_core is

    -- Коды микроопераций (µops)
    constant UOP_NOP  : std_logic_vector(3 downto 0) := "0000";
    constant UOP_MOV  : std_logic_vector(3 downto 0) := "0001";
    constant UOP_ADD  : std_logic_vector(3 downto 0) := "0010";
    constant UOP_SUB  : std_logic_vector(3 downto 0) := "0011";
    constant UOP_CMP  : std_logic_vector(3 downto 0) := "0100";
    constant UOP_JMP  : std_logic_vector(3 downto 0) := "0101";

begin

    ready_o <= '1';

    ----------------------------------------------------------------------------
    -- ДЕКОДЕР x86_64 (С обработкой REX префиксов и расширенных регистров R8-R15)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_byte0   : std_logic_vector(7 downto 0);
        variable v_byte1   : std_logic_vector(7 downto 0);
        variable v_byte2   : std_logic_vector(7 downto 0);
        variable v_has_rex : std_logic;
        variable v_rex_w   : std_logic;
        variable v_rex_r   : std_logic;
        variable v_rex_b   : std_logic;
        variable v_opcode_idx : integer;
        variable v_modrm   : std_logic_vector(7 downto 0);
        variable v_reg_dest: std_logic_vector(3 downto 0);
        variable v_reg_src : std_logic_vector(3 downto 0);
    begin
        if rst_n = '0' then
            uop_valid_o    <= '0';
            uop_type_o     <= UOP_NOP;
            uop_rex_w_o    <= '0';
            uop_reg_dest_o <= (others => '0');
            uop_reg_src_o  <= (others => '0');
            uop_imm_o      <= (others => '0');
        elsif rising_edge(clk) then
            if valid_i = '1' then
                -- Разбираем входящий поток байт (младшие байты идут первыми)
                v_byte0 := instruction_i(7 downto 0);
                v_byte1 := instruction_i(15 downto 8);
                v_byte2 := instruction_i(23 downto 16);

                -- Проверка на наличие REX префикса (диапазон 0x40 .. 0x4F)
                if v_byte0(7 downto 4) = "0100" then
                    v_has_rex := '1';
                    v_rex_w   := v_byte0(3); -- Бит ширины операнда (1 = 64-bit)
                    v_rex_r   := v_byte0(2); -- Расширение поля Reg в ModR/M (для регистров R8-R15)
                    v_rex_b   := v_byte0(0); -- Расширение поля R/M
                    
                    -- Если есть REX, то реальный опкод лежит в следующем байте
                    v_opcode_idx := 1;
                    if v_opcode_idx = 1 then
                        v_modrm := v_byte2;
                    else
                        v_modrm := (others => '0');
                    end if;
                else
                    v_has_rex := '0';
                    v_rex_w   := '0';
                    v_rex_r   := '0';
                    v_rex_b   := '0';
                    v_modrm   := v_byte1;
                end if;

                uop_valid_o <= '1';
                uop_rex_w_o <= v_rex_w;

                -- Формирование индексов регистров с учетом битов расширения REX.R и REX.B
                v_reg_dest := v_rex_r & v_modrm(5 downto 3);
                v_reg_src  := v_rex_b & v_modrm(2 downto 0);

                -- Декодирование базовых 64-битных инструкций x86_64
                if v_has_rex = '1' and v_byte1 = x"89" then -- MOV r/m64, r64
                    uop_type_o     <= UOP_MOV;
                    uop_reg_dest_o <= v_reg_dest;
                    uop_reg_src_o  <= v_reg_src;
                    uop_imm_o      <= (others => '0');
                elsif v_has_rex = '1' and v_byte1 = x"01" then -- ADD r/m64, r64
                    uop_type_o     <= UOP_ADD;
                    uop_reg_dest_o <= v_reg_dest;
                    uop_reg_src_o  <= v_reg_src;
                    uop_imm_o      <= (others => '0');
                elsif v_has_rex = '1' and v_byte1 = x"29" then -- SUB r/m64, r64
                    uop_type_o     <= UOP_SUB;
                    uop_reg_dest_o <= v_reg_dest;
                    uop_reg_src_o  <= v_reg_src;
                    uop_imm_o      <= (others => '0');
                else
                    -- Общий дефолтный случай / прямой проброс 64-битного значения
                    uop_type_o     <= UOP_MOV;
                    uop_reg_dest_o <= v_reg_dest;
                    uop_reg_src_o  <= v_reg_src;
                    uop_imm_o      <= instruction_i(63 downto 32) & x"0000000" & v_byte0;
                end if;
            else
                uop_valid_o <= '0';
            end if;
        end if;
    end process;

end architecture rtl;