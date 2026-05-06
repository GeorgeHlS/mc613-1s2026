library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- dram_iface: User interface for the DRAM controller
-- Interprets SW/KEY inputs and generates address/data/req/wEn signals
-- FSM: READY -> REQ_WRITE -> WAIT_WRITE -> REQ_READ -> WAIT_READ -> READY
--
-- Address mapping (from planejamento.md section 7.3):
--   SW(9)       -> address(25)
--   SW(8 downto 6) -> address(23 downto 21)
--   SW(5 downto 4) -> address(1 downto 0)
--   All other address bits = '0'
--
-- Data: SW(3 downto 0) -> data(3 downto 0), data(7 downto 4) = "0000"
--
-- KEY(3) = write trigger
-- ready from controller indicates operation complete

entity dram_iface is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        SW            : in  std_logic_vector(9 downto 0);
        KEY           : in  std_logic_vector(3 downto 0);
        ready         : in  std_logic;
        data_from_mem : in  std_logic_vector(7 downto 0);

        HEX0    : out std_logic_vector(6 downto 0);  -- write data display
        HEX1    : out std_logic_vector(6 downto 0);  -- read data display
        HEX4    : out std_logic_vector(6 downto 0);  -- address low
        HEX5    : out std_logic_vector(6 downto 0);  -- address high
        address : out std_logic_vector(25 downto 0);
        data_to_mem : out std_logic_vector(7 downto 0);
        req     : out std_logic;
        wEn     : out std_logic
    );
end entity dram_iface;

architecture rtl of dram_iface is

    type state_t is (S_READY, S_REQ_WRITE, S_WAIT_WRITE, S_REQ_READ, S_WAIT_READ);
    signal state, next_state : state_t;

    signal read_data_reg  : std_logic_vector(7 downto 0);
    signal write_data_reg : std_logic_vector(3 downto 0);
    signal sw_reg         : std_logic_vector(9 downto 0);

    -- Edge detection for KEY(3)
    signal key3_prev  : std_logic;
    signal key3_pulse : std_logic;

    -- Address mapping
    signal mapped_address : std_logic_vector(25 downto 0);
    signal prev_address   : std_logic_vector(25 downto 0);
    signal addr_changed   : std_logic;

begin

    -- Address mapping (section 7.3 of planejamento)
    mapped_address(25)           <= SW(9);
    mapped_address(24)           <= '0';
    mapped_address(23 downto 21) <= SW(8 downto 6);
    mapped_address(20 downto 2)  <= (others => '0');
    mapped_address(1 downto 0)   <= SW(5 downto 4);

    -- Edge detection for KEY(3) write button
    process(clk, rst)
    begin
        if rst = '1' then
            key3_prev <= '0';
        elsif rising_edge(clk) then
            key3_prev <= KEY(3);
        end if;
    end process;
    key3_pulse <= KEY(3) and (not key3_prev);

    -- Previous address register (for change detection)
    process(clk, rst)
    begin
        if rst = '1' then
            prev_address <= (others => '0');
        elsif rising_edge(clk) then
            prev_address <= mapped_address;
        end if;
    end process;

    addr_changed <= '1' when mapped_address /= prev_address else '0';

    -- State register
    process(clk, rst)
    begin
        if rst = '1' then
            state <= S_READY;
        elsif rising_edge(clk) then
            state <= next_state;
        end if;
    end process;

    -- Next state logic (section 7.2 of planejamento)
    process(state, key3_pulse, ready, addr_changed)
    begin
        next_state <= state;
        case state is
            when S_READY =>
                if key3_pulse = '1' and ready = '1' then
                    next_state <= S_REQ_WRITE;
                elsif addr_changed = '1' and ready = '1' then
                    next_state <= S_REQ_READ;
                end if;

            when S_REQ_WRITE =>
                next_state <= S_WAIT_WRITE;  -- 1-cycle pulse

            when S_WAIT_WRITE =>
                if ready = '1' then
                    next_state <= S_REQ_READ;  -- auto read-back after write
                end if;

            when S_REQ_READ =>
                next_state <= S_WAIT_READ;  -- 1-cycle pulse

            when S_WAIT_READ =>
                if ready = '1' then
                    next_state <= S_READY;
                end if;
        end case;
    end process;

    -- Output logic
    process(clk, rst)
    begin
        if rst = '1' then
            address        <= (others => '0');
            data_to_mem    <= (others => '0');
            req            <= '0';
            wEn            <= '0';
            read_data_reg  <= (others => '0');
            write_data_reg <= (others => '0');
            sw_reg         <= (others => '0');
        elsif rising_edge(clk) then
            sw_reg  <= SW;
            address <= mapped_address;

            case state is
                when S_READY =>
                    req <= '0';
                    wEn <= '0';

                when S_REQ_WRITE =>
                    req         <= '1';
                    wEn         <= '1';
                    data_to_mem <= "0000" & SW(3 downto 0);
                    write_data_reg <= SW(3 downto 0);

                when S_WAIT_WRITE =>
                    req <= '0';
                    wEn <= '0';

                when S_REQ_READ =>
                    req <= '1';
                    wEn <= '0';

                when S_WAIT_READ =>
                    req <= '0';
                    if ready = '1' then
                        read_data_reg <= data_from_mem;
                    end if;
            end case;
        end if;
    end process;

    -- 7-segment displays
    hex0_inst: entity work.hex_decoder port map (value => write_data_reg, hex => HEX0);
    hex1_inst: entity work.hex_decoder port map (value => read_data_reg(3 downto 0), hex => HEX1);
    hex4_inst: entity work.hex_decoder port map (value => "00" & sw_reg(5 downto 4), hex => HEX4);
    hex5_inst: entity work.hex_decoder port map (value => sw_reg(9 downto 6), hex => HEX5);

end architecture rtl;
