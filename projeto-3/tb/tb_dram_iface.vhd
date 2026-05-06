library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_dram_iface is
end entity tb_dram_iface;

architecture sim of tb_dram_iface is

    signal clk           : std_logic := '0';
    signal rst           : std_logic;
    signal SW            : std_logic_vector(9 downto 0);
    signal KEY           : std_logic_vector(3 downto 0);
    signal ready         : std_logic;
    signal data_from_mem : std_logic_vector(7 downto 0);
    signal HEX0, HEX1, HEX4, HEX5 : std_logic_vector(6 downto 0);
    signal address       : std_logic_vector(25 downto 0);
    signal data_to_mem   : std_logic_vector(7 downto 0);
    signal req           : std_logic;
    signal wEn           : std_logic;

    constant CLK_PERIOD : time := 7 ns;  -- 143 MHz

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut: entity work.dram_iface
        port map (
            clk           => clk,
            rst           => rst,
            SW            => SW,
            KEY           => KEY,
            ready         => ready,
            data_from_mem => data_from_mem,
            HEX0          => HEX0,
            HEX1          => HEX1,
            HEX4          => HEX4,
            HEX5          => HEX5,
            address       => address,
            data_to_mem   => data_to_mem,
            req           => req,
            wEn           => wEn
        );

    process
    begin
        -- Initialize
        rst           <= '1';
        SW            <= (others => '0');
        KEY           <= (others => '0');
        ready         <= '0';
        data_from_mem <= (others => '0');
        wait for 50 ns;
        rst <= '0';
        wait for 20 ns;

        -- Test 1: Write operation
        report "--- Test 1: Write operation ---";
        SW    <= "0000011010";  -- addr: bank0, row=0, col=1, data=0xA
        ready <= '1';
        wait for 20 ns;

        KEY(3) <= '1';
        wait for CLK_PERIOD;
        KEY(3) <= '0';
        wait for CLK_PERIOD;
        report "req=" & std_logic'image(req) & " wEn=" & std_logic'image(wEn);

        wait for 2 * CLK_PERIOD;
        report "WAIT_WRITE: req=" & std_logic'image(req) & " wEn=" & std_logic'image(wEn);

        ready <= '1';
        wait for CLK_PERIOD;
        report "REQ_READ: req=" & std_logic'image(req) & " wEn=" & std_logic'image(wEn);

        wait for CLK_PERIOD;
        data_from_mem <= x"0A";
        ready <= '1';
        wait for 2 * CLK_PERIOD;
        report "Back to READY";

        -- Test 2: Address change
        report "--- Test 2: Address change ---";
        SW <= "1011100101";
        wait for 20 ns;

        -- Test 3: Reset during operation
        report "--- Test 3: Reset ---";
        KEY(3) <= '1';
        wait for CLK_PERIOD;
        KEY(3) <= '0';
        wait for 2 * CLK_PERIOD;
        rst <= '1';
        wait for 20 ns;
        rst <= '0';
        wait for 20 ns;
        report "After reset: req=" & std_logic'image(req) & " wEn=" & std_logic'image(wEn);

        wait for 100 ns;
        report "=== All dram_iface tests completed ===";
        wait;
    end process;

end architecture sim;
