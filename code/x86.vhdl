library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.vinpu_arch_pkg.all;

entity x86_core is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Входной поток байтов x86-инструкций от хоста / памяти
        instruction_i   : in  std_logic_vector(31 downto 0); -- 4 байта инструкции за такт
        valid_i         : in  std_logic;
        ready_o         : out std_logic;

        -- Выход декодированных микроопераций (µops) на конвейер ViNPU / ALU
        uop_valid_o     : out std_logic;
        uop_type_o      : out std_logic_vector(3 downto 0);  -- Тип операции (MOV, ADD, SUB, CMP, JMP)
        uop_reg_dest_o  : out std_logic_vector(3 downto 0);  -- Индекс целевого регистра (EAX, EBX, etc.)
        uop_reg_src_o   : out std_logic_vector(3 downto 0);  -- Индекс исходного регистра
        uop_imm_o       : out std_logic_vector(31 downto 0)  -- Непосредственное значение / смещение
    );
end entity x86_core;

architecture rtl of x86_core is

    -- Внутренние коды микроопераций (µops)
    constant UOP_NOP  : std_logic_vector(3 downto 0) := "0000";
    constant UOP_MOV  : std_logic_vector(3 downto 0) := "0001";
    constant UOP_ADD  : std_logic_vector(3 downto 0) := "0010";
    constant UOP_SUB  : std_logic_vector(3 downto 0) := "0011";
    constant UOP_CMP  : std_logic_vector(3 downto 0) := "0100";
    constant UOP_JMP  : std_logic_vector(3 downto 0) := "0101";

    signal state_ready : std_logic;

begin

    ready_o <= '1'; -- Ядро готово принимать байты непрерывно

    ----------------------------------------------------------------------------
    -- ДЕКОДЕР x86 ОПКОДОВ В МИКРООПЕРАЦИИ (µops)
    ----------------------------------------------------------------------------
    process(clk, rst_n)
        variable v_opcode : std_logic_vector(7 downto 0);
        variable v_modrm  : std_logic_vector(7 downto 0);
    begin
        if rst_n = '0' then
            uop_valid_o    <= '0';
            uop_type_o     <= UOP_NOP;
            uop_reg_dest_o <= (others => '0');
            uop_reg_src_o  <= (others => '0');
            uop_imm_o      <= (others => '0');
        elsif rising_edge(clk) then
            if valid_i = '1' then
                -- Извлекаем первый байт инструкции (Primary Opcode) с младших разрядов шины
                v_opcode := instruction_i(7 downto 0);
                v_modrm  := instruction_i(15 downto 8);

                uop_valid_o <= '1';
                
                -- Простейший хардварный маппинг популярных x86 опкодов
                case v_opcode is
                    when x"89" => -- MOV r/m32, r32 (регистр в регистр/память)
                        uop_type_o     <= UOP_MOV;
                        uop_reg_dest_o <= v_modrm(5 downto 2); -- Reg поле ModR/M
                        uop_reg_src_o  <= v_modrm(2 downto 0); -- R/M поле
                        uop_imm_o      <= (others => '0');

                    when x"01" => -- ADD r/m32, r32
                        uop_type_o     <= UOP_ADD;
                        uop_reg_dest_o <= v_modrm(5 downto 2);
                        uop_reg_src_o  <= v_modrm(2 downto 0);
                        uop_imm_o      <= (others => '0');

                    when x"29" => -- SUB r/m32, r32
                        uop_type_o     <= UOP_SUB;
                        uop_reg_dest_o <= v_modrm(5 downto 2);
                        uop_reg_src_o  <= v_modrm(2 downto 0);
                        uop_imm_o      <= (others => '0');

                    when x"39" => -- CMP r/m32, r32
                        uop_type_o     <= UOP_CMP;
                        uop_reg_dest_o <= v_modrm(5 downto 2);
                        uop_reg_src_o  <= v_modrm(2 downto 0);
                        uop_imm_o      <= (others => '0');

                    when x"EB" => -- JMP rel8 (короткий относительный переход)
                        uop_type_o     <= UOP_JMP;
                        uop_reg_dest_o <= (others => '0');
                        uop_reg_src_o  <= (others => '0');
                        uop_imm_o      <= x"000000" & instruction_i(15 downto 8); -- смещение rel8

                    when others =>
                        uop_type_o     <= UOP_NOP;
                        uop_reg_dest_o <= (others => '0');
                        uop_reg_src_o  <= (others => '0');
                        uop_imm_o      <= instruction_i(31 downto 8);
                end case;
            else
                uop_valid_o <= '0';
            end if;
        end if;
    end process;

end architecture rtl;