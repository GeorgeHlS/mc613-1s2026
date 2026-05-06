library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dram_iface is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        SW            : in  std_logic_vector(9 downto 0);
        KEY           : in  std_logic_vector(3 downto 0);
        ready         : in  std_logic;
        data_from_mem : in  std_logic_vector(7 downto 0);

        HEX0    : out std_logic_vector(6 downto 0);
        HEX1    : out std_logic_vector(6 downto 0);
        HEX4    : out std_logic_vector(6 downto 0);
        HEX5    : out std_logic_vector(6 downto 0);
        address : out std_logic_vector(25 downto 0);
        data_to_mem : out std_logic_vector(7 downto 0);
        req     : out std_logic;
        wEn     : out std_logic;
        dbg_state : out std_logic_vector(2 downto 0)
    );
end entity dram_iface;

architecture rtl of dram_iface is

    type state_t is (S_IDLE, S_WRITE, S_WAIT_WRITE, S_READ, S_WAIT_READ);
    signal state : state_t;

    signal read_data_reg  : std_logic_vector(7 downto 0);
    signal write_data_reg : std_logic_vector(3 downto 0);
    signal sw_reg         : std_logic_vector(9 downto 0);

    -- Edge detection for KEY(3)
    signal key3_prev  : std_logic;
    signal key3_pulse : std_logic;

    -- Address mapping
    signal mapped_address : std_logic_vector(25 downto 0);

    -- Ready edge detection (rising edge = operation completed)
    signal ready_prev  : std_logic;
    signal ready_rose  : std_logic;

begin

    -- Address mapping
    mapped_address(25)           <= SW(9);
    mapped_address(24)           <= '0';
    mapped_address(23 downto 21) <= SW(8 downto 6);
    mapped_address(20 downto 2)  <= (others => '0');
    mapped_address(1 downto 0)   <= SW(5 downto 4);

    -- Edge detection for KEY(3) write button
    process(clk, rst)
    begin
        if rst = '1' then
            key3_prev  <= '0';
            ready_prev <= '0';
        elsif rising_edge(clk) then
            key3_prev  <= KEY(3);
            ready_prev <= ready;
        end if;
    end process;
    key3_pulse <= KEY(3) and (not key3_prev);
    ready_rose <= ready and (not ready_prev);

    -- Single process FSM
    process(clk, rst)
    begin
        if rst = '1' then
            state          <= S_IDLE;
            address        <= (others => '0');
            data_to_mem    <= (others => '0');
            req            <= '0';
            wEn            <= '0';
            read_data_reg  <= (others => '0');
            write_data_reg <= (others => '0');
            sw_reg         <= (others => '0');
        elsif rising_edge(clk) then
            sw_reg <= SW;

            case state is
                when S_IDLE =>
                    req <= '0';
                    wEn <= '0';
                    if key3_pulse = '1' and ready = '1' then
                        -- Start write operation
                        state       <= S_WRITE;
                        address     <= mapped_address;
                        data_to_mem <= "0000" & SW(3 downto 0);
                        write_data_reg <= SW(3 downto 0);
                        req         <= '1';
                        wEn         <= '1';
                    end if;

                when S_WRITE =>
                    -- Keep req/wEn high until controller accepts (ready goes low)
                    if ready = '0' then
                        -- Controller accepted the request
                        req   <= '0';
                        wEn   <= '0';
                        state <= S_WAIT_WRITE;
                    end if;

                when S_WAIT_WRITE =>
                    -- Wait for write to complete (ready goes high again)
                    if ready_rose = '1' then
                        -- Write done, now do read-back
                        state   <= S_READ;
                        req     <= '1';
                        wEn     <= '0';
                    end if;

                when S_READ =>
                    -- Keep req high until controller accepts (ready goes low)
                    if ready = '0' then
                        req   <= '0';
                        state <= S_WAIT_READ;
                    end if;

                when S_WAIT_READ =>
                    -- Wait for read to complete
                    if ready_rose = '1' then
                        read_data_reg <= data_from_mem;
                        state         <= S_IDLE;
                    end if;
            end case;
        end if;
    end process;

    -- 7-segment displays
    hex0_inst: entity work.hex_decoder port map (value => write_data_reg, hex => HEX0);
    hex1_inst: entity work.hex_decoder port map (value => read_data_reg(3 downto 0), hex => HEX1);
    hex4_inst: entity work.hex_decoder port map (value => "00" & sw_reg(5 downto 4), hex => HEX4);
    hex5_inst: entity work.hex_decoder port map (value => sw_reg(9 downto 6), hex => HEX5);

    -- Debug: encode FSM state
    dbg_state <= "000" when state = S_IDLE else
                 "001" when state = S_WRITE else
                 "010" when state = S_WAIT_WRITE else
                 "011" when state = S_READ else
                 "100" when state = S_WAIT_READ else
                 "111";

end architecture rtl;
