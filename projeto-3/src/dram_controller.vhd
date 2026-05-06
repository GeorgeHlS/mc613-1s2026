library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dram_controller is
    port (
        clk       : in    std_logic;
        rst       : in    std_logic;
        address   : in    std_logic_vector(25 downto 0);
        data_in   : in    std_logic_vector(7 downto 0);
        req       : in    std_logic;
        wEn       : in    std_logic;
        ready     : out   std_logic;
        data_out  : out   std_logic_vector(7 downto 0);
        DRAM_CLK  : out   std_logic;
        DRAM_CKE  : out   std_logic;
        DRAM_CS_N : out   std_logic;
        DRAM_RAS_N: out   std_logic;
        DRAM_CAS_N: out   std_logic;
        DRAM_WE_N : out   std_logic;
        DRAM_BA   : out   std_logic_vector(1 downto 0);
        DRAM_ADDR : out   std_logic_vector(12 downto 0);
        DRAM_DQ   : inout std_logic_vector(15 downto 0);
        DRAM_UDQM : out   std_logic;
        DRAM_LDQM : out   std_logic
    );
end entity dram_controller;

architecture rtl of dram_controller is

    -- Timing parameters (clock cycles at 143 MHz)
    constant TRCD             : integer := 3;
    constant TCAS             : integer := 3;
    constant TRP              : integer := 3;
    constant TRC              : integer := 9;
    constant TDPL             : integer := 2;
    constant TMRD             : integer := 2;
    constant INIT_WAIT        : integer := 30000;
    constant REFRESH_INTERVAL : integer := 1100;
    constant INIT_REFRESH_COUNT : integer := 8;

    -- SDRAM commands {CS_N, RAS_N, CAS_N, WE_N}
    constant CMD_NOP       : std_logic_vector(3 downto 0) := "0111";
    constant CMD_ACTIVATE  : std_logic_vector(3 downto 0) := "0011";
    constant CMD_READ      : std_logic_vector(3 downto 0) := "0101";
    constant CMD_WRITE     : std_logic_vector(3 downto 0) := "0100";
    constant CMD_PRECHARGE : std_logic_vector(3 downto 0) := "0010";
    constant CMD_REFRESH   : std_logic_vector(3 downto 0) := "0001";
    constant CMD_LMR       : std_logic_vector(3 downto 0) := "0000";
    constant CMD_INHIBIT   : std_logic_vector(3 downto 0) := "1111";

    -- Mode register: BL=1, Sequential, CAS=3, Standard, Write Burst=Single
    constant MODE_REG : std_logic_vector(12 downto 0) := "0001000110000";

    -- FSM states
    type state_t is (
        ST_INIT_WAIT, ST_INIT_PRECHARGE, ST_INIT_WAIT_RP,
        ST_INIT_REFRESH, ST_INIT_WAIT_RC, ST_INIT_LMR, ST_INIT_WAIT_MRD,
        ST_READY,
        ST_ACTIVATE, ST_WAIT_TRCD,
        ST_READ, ST_WAIT_CAS, ST_READ_CAPTURE,
        ST_WRITE, ST_WAIT_TDPL,
        ST_PRECHARGE, ST_WAIT_TRP,
        ST_REFRESH, ST_WAIT_TRC
    );

    signal state, next_state : state_t;
    signal counter           : unsigned(14 downto 0);
    signal refresh_counter   : unsigned(10 downto 0);
    signal init_refresh_cnt  : unsigned(3 downto 0);
    signal refresh_needed    : std_logic;
    signal op_is_write       : std_logic;
    signal latched_addr      : std_logic_vector(25 downto 0);
    signal latched_data      : std_logic_vector(7 downto 0);
    signal latched_byte_sel  : std_logic;

    -- DQ bus control
    signal dq_oe  : std_logic;
    signal dq_out : std_logic_vector(15 downto 0);

    -- Command signal (internal, applied to outputs)
    signal cmd : std_logic_vector(3 downto 0);

    -- Internal copies of outputs for reading back
    signal ready_i    : std_logic;
    signal data_out_i : std_logic_vector(7 downto 0);
    signal ba_i       : std_logic_vector(1 downto 0);
    signal addr_i     : std_logic_vector(12 downto 0);
    signal udqm_i     : std_logic;
    signal ldqm_i     : std_logic;
    signal cke_i      : std_logic;

begin

    -- DQ tristate
    DRAM_DQ <= dq_out when dq_oe = '1' else (others => 'Z');

    -- DRAM clock inverted (180° phase shift for setup/hold timing)
    DRAM_CLK <= not clk;

    -- Map command to output pins
    DRAM_CS_N  <= cmd(3);
    DRAM_RAS_N <= cmd(2);
    DRAM_CAS_N <= cmd(1);
    DRAM_WE_N  <= cmd(0);

    -- Map internal signals to outputs
    ready     <= ready_i;
    data_out  <= data_out_i;
    DRAM_BA   <= ba_i;
    DRAM_ADDR <= addr_i;
    DRAM_UDQM <= udqm_i;
    DRAM_LDQM <= ldqm_i;
    DRAM_CKE  <= cke_i;

    -- Refresh timer
    process(clk, rst)
    begin
        if rst = '1' then
            refresh_counter <= (others => '0');
            refresh_needed  <= '0';
        elsif rising_edge(clk) then
            if state = ST_INIT_WAIT or state = ST_INIT_PRECHARGE or
               state = ST_INIT_WAIT_RP or state = ST_INIT_REFRESH or
               state = ST_INIT_WAIT_RC or state = ST_INIT_LMR or
               state = ST_INIT_WAIT_MRD then
                refresh_counter <= (others => '0');
                refresh_needed  <= '0';
            else
                if refresh_counter >= to_unsigned(REFRESH_INTERVAL, 11) then
                    refresh_counter <= (others => '0');
                    refresh_needed  <= '1';
                else
                    refresh_counter <= refresh_counter + 1;
                end if;
                if state = ST_REFRESH then
                    refresh_needed <= '0';
                end if;
            end if;
        end if;
    end process;

    -- State register and counters
    process(clk, rst)
    begin
        if rst = '1' then
            state            <= ST_INIT_WAIT;
            counter          <= (others => '0');
            init_refresh_cnt <= (others => '0');
        elsif rising_edge(clk) then
            state <= next_state;

            case state is
                when ST_INIT_WAIT =>
                    if counter < to_unsigned(INIT_WAIT, 15) then
                        counter <= counter + 1;
                    else
                        counter <= (others => '0');
                    end if;

                when ST_INIT_WAIT_RP | ST_WAIT_TRCD | ST_WAIT_CAS |
                     ST_WAIT_TDPL | ST_WAIT_TRP | ST_WAIT_TRC |
                     ST_INIT_WAIT_RC | ST_INIT_WAIT_MRD =>
                    counter <= counter + 1;

                when others =>
                    counter <= (others => '0');
            end case;

            -- Init refresh counter
            if state = ST_INIT_WAIT_RC and counter >= to_unsigned(TRC - 1, 15) then
                init_refresh_cnt <= init_refresh_cnt + 1;
            end if;
        end if;
    end process;

    -- Next state logic
    process(state, counter, init_refresh_cnt, refresh_needed, req, op_is_write)
    begin
        next_state <= state;
        case state is
            when ST_INIT_WAIT =>
                if counter >= to_unsigned(INIT_WAIT, 15) then
                    next_state <= ST_INIT_PRECHARGE;
                end if;
            when ST_INIT_PRECHARGE =>
                next_state <= ST_INIT_WAIT_RP;
            when ST_INIT_WAIT_RP =>
                if counter >= to_unsigned(TRP - 1, 15) then
                    next_state <= ST_INIT_REFRESH;
                end if;
            when ST_INIT_REFRESH =>
                next_state <= ST_INIT_WAIT_RC;
            when ST_INIT_WAIT_RC =>
                if counter >= to_unsigned(TRC - 1, 15) then
                    if init_refresh_cnt >= to_unsigned(INIT_REFRESH_COUNT - 1, 4) then
                        next_state <= ST_INIT_LMR;
                    else
                        next_state <= ST_INIT_REFRESH;
                    end if;
                end if;
            when ST_INIT_LMR =>
                next_state <= ST_INIT_WAIT_MRD;
            when ST_INIT_WAIT_MRD =>
                if counter >= to_unsigned(TMRD - 1, 15) then
                    next_state <= ST_READY;
                end if;

            when ST_READY =>
                if refresh_needed = '1' then
                    next_state <= ST_REFRESH;
                elsif req = '1' then
                    next_state <= ST_ACTIVATE;
                end if;
            when ST_ACTIVATE =>
                next_state <= ST_WAIT_TRCD;
            when ST_WAIT_TRCD =>
                if counter >= to_unsigned(TRCD - 1, 15) then
                    if op_is_write = '1' then
                        next_state <= ST_WRITE;
                    else
                        next_state <= ST_READ;
                    end if;
                end if;

            when ST_READ =>
                next_state <= ST_WAIT_CAS;
            when ST_WAIT_CAS =>
                if counter >= to_unsigned(TCAS - 1, 15) then
                    next_state <= ST_READ_CAPTURE;
                end if;
            when ST_READ_CAPTURE =>
                next_state <= ST_PRECHARGE;

            when ST_WRITE =>
                next_state <= ST_WAIT_TDPL;
            when ST_WAIT_TDPL =>
                if counter >= to_unsigned(TDPL - 1, 15) then
                    next_state <= ST_PRECHARGE;
                end if;

            when ST_PRECHARGE =>
                next_state <= ST_WAIT_TRP;
            when ST_WAIT_TRP =>
                if counter >= to_unsigned(TRP - 1, 15) then
                    next_state <= ST_READY;
                end if;

            when ST_REFRESH =>
                next_state <= ST_WAIT_TRC;
            when ST_WAIT_TRC =>
                if counter >= to_unsigned(TRC - 1, 15) then
                    next_state <= ST_READY;
                end if;
        end case;
    end process;

    -- Output logic
    process(clk, rst)
    begin
        if rst = '1' then
            cke_i          <= '1';
            cmd            <= CMD_INHIBIT;
            ba_i           <= "00";
            addr_i         <= (others => '0');
            udqm_i         <= '1';
            ldqm_i         <= '1';
            dq_oe          <= '0';
            dq_out         <= (others => '0');
            ready_i        <= '0';
            data_out_i     <= (others => '0');
            op_is_write    <= '0';
            latched_addr   <= (others => '0');
            latched_data   <= (others => '0');
            latched_byte_sel <= '0';
        elsif rising_edge(clk) then
            -- Defaults
            cmd   <= CMD_NOP;
            dq_oe <= '0';
            cke_i <= '1';

            case state is
                when ST_INIT_WAIT =>
                    ready_i <= '0';
                    cmd     <= CMD_INHIBIT;
                    udqm_i  <= '1';
                    ldqm_i  <= '1';

                when ST_INIT_PRECHARGE =>
                    cmd     <= CMD_PRECHARGE;
                    addr_i(10) <= '1';  -- all banks

                when ST_INIT_WAIT_RP =>
                    cmd <= CMD_NOP;

                when ST_INIT_REFRESH =>
                    cmd <= CMD_REFRESH;

                when ST_INIT_WAIT_RC =>
                    cmd <= CMD_NOP;

                when ST_INIT_LMR =>
                    cmd    <= CMD_LMR;
                    ba_i   <= "00";
                    addr_i <= MODE_REG;

                when ST_INIT_WAIT_MRD =>
                    cmd <= CMD_NOP;
                    if counter >= to_unsigned(TMRD - 1, 15) then
                        ready_i <= '1';
                    end if;

                when ST_READY =>
                    ready_i <= '1';
                    udqm_i  <= '0';
                    ldqm_i  <= '0';
                    if req = '1' and refresh_needed = '0' then
                        op_is_write      <= wEn;
                        latched_addr     <= address;
                        latched_data     <= data_in;
                        latched_byte_sel <= address(0);
                        ready_i          <= '0';
                    end if;

                when ST_ACTIVATE =>
                    ready_i <= '0';
                    cmd     <= CMD_ACTIVATE;
                    ba_i    <= latched_addr(25 downto 24);
                    addr_i  <= latched_addr(23 downto 11);

                when ST_WAIT_TRCD =>
                    cmd <= CMD_NOP;

                when ST_READ =>
                    cmd    <= CMD_READ;
                    ba_i   <= latched_addr(25 downto 24);
                    addr_i <= "000" & latched_addr(10 downto 1);
                    addr_i(10) <= '0';  -- no auto-precharge
                    -- DQM=0 for both bytes during read (select byte at capture)
                    ldqm_i <= '0';
                    udqm_i <= '0';

                when ST_WAIT_CAS =>
                    cmd <= CMD_NOP;
                    -- Capture data on the last CAS wait cycle (data valid now)
                    if counter >= to_unsigned(TCAS - 2, 15) then
                        if latched_byte_sel = '1' then
                            data_out_i <= DRAM_DQ(15 downto 8);
                        else
                            data_out_i <= DRAM_DQ(7 downto 0);
                        end if;
                    end if;

                when ST_READ_CAPTURE =>
                    cmd <= CMD_NOP;
                    -- Also capture here as backup (data may still be on bus)
                    if latched_byte_sel = '1' then
                        data_out_i <= DRAM_DQ(15 downto 8);
                    else
                        data_out_i <= DRAM_DQ(7 downto 0);
                    end if;

                when ST_WRITE =>
                    cmd    <= CMD_WRITE;
                    ba_i   <= latched_addr(25 downto 24);
                    addr_i <= "000" & latched_addr(10 downto 1);
                    addr_i(10) <= '0';
                    dq_oe  <= '1';
                    if latched_byte_sel = '1' then
                        dq_out <= latched_data & x"00";
                        ldqm_i <= '1';
                        udqm_i <= '0';
                    else
                        dq_out <= x"00" & latched_data;
                        ldqm_i <= '0';
                        udqm_i <= '1';
                    end if;

                when ST_WAIT_TDPL =>
                    cmd   <= CMD_NOP;
                    dq_oe <= '0';

                when ST_PRECHARGE =>
                    cmd        <= CMD_PRECHARGE;
                    addr_i(10) <= '1';  -- all banks

                when ST_WAIT_TRP =>
                    cmd <= CMD_NOP;
                    if counter >= to_unsigned(TRP - 1, 15) then
                        ready_i <= '1';
                    end if;

                when ST_REFRESH =>
                    ready_i <= '0';
                    cmd     <= CMD_REFRESH;

                when ST_WAIT_TRC =>
                    cmd <= CMD_NOP;
                    if counter >= to_unsigned(TRC - 1, 15) then
                        ready_i <= '1';
                    end if;
            end case;
        end if;
    end process;

end architecture rtl;
