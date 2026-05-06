library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_dram_controller is
end entity tb_dram_controller;

architecture sim of tb_dram_controller is

    signal clk        : std_logic := '0';
    signal rst        : std_logic;
    signal address    : std_logic_vector(25 downto 0);
    signal data_in    : std_logic_vector(7 downto 0);
    signal req        : std_logic;
    signal wEn        : std_logic;
    signal ready      : std_logic;
    signal data_out   : std_logic_vector(7 downto 0);
    signal DRAM_CLK   : std_logic;
    signal DRAM_CKE   : std_logic;
    signal DRAM_CS_N  : std_logic;
    signal DRAM_RAS_N : std_logic;
    signal DRAM_CAS_N : std_logic;
    signal DRAM_WE_N  : std_logic;
    signal DRAM_BA    : std_logic_vector(1 downto 0);
    signal DRAM_ADDR  : std_logic_vector(12 downto 0);
    signal DRAM_DQ    : std_logic_vector(15 downto 0);
    signal DRAM_UDQM  : std_logic;
    signal DRAM_LDQM  : std_logic;

    -- Simple SDRAM model signals
    signal dq_drive    : std_logic_vector(15 downto 0) := (others => '0');
    signal dq_drive_en : std_logic := '0';

    constant CLK_PERIOD : time := 7 ns;

    -- Command alias
    signal cmd : std_logic_vector(3 downto 0);

begin

    clk <= not clk after CLK_PERIOD / 2;
    cmd <= DRAM_CS_N & DRAM_RAS_N & DRAM_CAS_N & DRAM_WE_N;

    -- DQ bus from memory model
    DRAM_DQ <= dq_drive when dq_drive_en = '1' else (others => 'Z');

    uut: entity work.dram_controller
        port map (
            clk        => clk,
            rst        => rst,
            address    => address,
            data_in    => data_in,
            req        => req,
            wEn        => wEn,
            ready      => ready,
            data_out   => data_out,
            DRAM_CLK   => DRAM_CLK,
            DRAM_CKE   => DRAM_CKE,
            DRAM_CS_N  => DRAM_CS_N,
            DRAM_RAS_N => DRAM_RAS_N,
            DRAM_CAS_N => DRAM_CAS_N,
            DRAM_WE_N  => DRAM_WE_N,
            DRAM_BA    => DRAM_BA,
            DRAM_ADDR  => DRAM_ADDR,
            DRAM_DQ    => DRAM_DQ,
            DRAM_UDQM  => DRAM_UDQM,
            DRAM_LDQM  => DRAM_LDQM
        );

    -- Simple memory model: after READ command, drive data after CAS latency
    mem_model: process(clk)
        variable cas_count : integer := 0;
    begin
        if rising_edge(clk) then
            dq_drive_en <= '0';

            if cmd = "0101" then  -- READ command
                cas_count := 3;
                report "[SDRAM] READ cmd issued";
            end if;

            if cmd = "0100" then  -- WRITE command
                report "[SDRAM] WRITE cmd, DQ=" & to_hstring(DRAM_DQ);
            end if;

            if cmd = "0011" then  -- ACTIVATE
                report "[SDRAM] ACTIVATE bank=" & to_hstring(DRAM_BA) & " row=" & to_hstring(DRAM_ADDR);
            end if;

            if cmd = "0010" then  -- PRECHARGE
                report "[SDRAM] PRECHARGE A10=" & std_logic'image(DRAM_ADDR(10));
            end if;

            if cmd = "0001" then  -- AUTO REFRESH
                report "[SDRAM] AUTO REFRESH";
            end if;

            if cmd = "0000" then  -- LOAD MODE REG
                report "[SDRAM] LOAD MODE REG = " & to_hstring(DRAM_ADDR);
            end if;

            if cas_count > 0 then
                cas_count := cas_count - 1;
                if cas_count = 0 then
                    dq_drive_en <= '1';
                    dq_drive    <= x"005A";  -- test read data
                    report "[SDRAM] Driving read data: 005A";
                end if;
            end if;
        end if;
    end process;

    -- Command monitor
    cmd_monitor: process(clk)
    begin
        if rising_edge(clk) then
            if DRAM_CS_N = '0' and cmd /= "0111" then  -- not NOP
                report "[CMD] CS=" & std_logic'image(DRAM_CS_N) &
                       " RAS=" & std_logic'image(DRAM_RAS_N) &
                       " CAS=" & std_logic'image(DRAM_CAS_N) &
                       " WE="  & std_logic'image(DRAM_WE_N) &
                       " BA="  & to_hstring(DRAM_BA) &
                       " ADDR=" & to_hstring(DRAM_ADDR);
            end if;
        end if;
    end process;

    -- Stimulus
    stim: process
    begin
        rst     <= '1';
        address <= (others => '0');
        data_in <= (others => '0');
        req     <= '0';
        wEn     <= '0';
        wait for 50 ns;
        rst <= '0';

        -- Test 1: Wait for INIT
        report "=== Test 1: INIT sequence ===";
        wait until ready = '1';
        report "INIT complete!";
        wait for 20 ns;

        -- Test 2: WRITE 0x5A to address 0
        report "=== Test 2: WRITE 0x5A to addr 0 ===";
        address <= (others => '0');
        data_in <= x"5A";
        wEn     <= '1';
        req     <= '1';
        wait for CLK_PERIOD;
        req <= '0';
        wEn <= '0';
        wait until ready = '1';
        report "WRITE complete!";
        wait for 20 ns;

        -- Test 3: READ from address 0
        report "=== Test 3: READ from addr 0 ===";
        address <= (others => '0');
        data_in <= (others => '0');
        wEn     <= '0';
        req     <= '1';
        wait for CLK_PERIOD;
        req <= '0';
        wait until ready = '1';
        report "READ complete! data_out=" & to_hstring(data_out);
        wait for 20 ns;

        -- Test 4: Wait for automatic REFRESH
        report "=== Test 4: Waiting for REFRESH ===";
        wait for 10000 ns;
        report "Refresh should have occurred";

        -- Test 5: Back-to-back WRITE then READ at different address
        report "=== Test 5: WRITE 0xAB to addr 0x200000, then READ ===";
        address <= "00" & x"200000";
        data_in <= x"AB";
        wEn     <= '1';
        req     <= '1';
        wait for CLK_PERIOD;
        req <= '0';
        wEn <= '0';
        wait until ready = '1';
        report "WRITE done";

        wait for 2 * CLK_PERIOD;
        wEn <= '0';
        req <= '1';
        wait for CLK_PERIOD;
        req <= '0';
        wait until ready = '1';
        report "READ done! data_out=" & to_hstring(data_out);

        wait for 200 ns;
        report "=== All dram_controller tests completed ===";
        wait;
    end process;

end architecture sim;
