library ieee;
use ieee.std_logic_1164.all;

-- Top-level for DE1-SoC checkpoint testing
-- SW(9)=0: DEBUG mode - KEY(1) simulates 'ready' for testing dram_iface alone
-- SW(9)=1: FULL mode  - dram_controller provides 'ready'
-- LEDs: LEDR(0)=req, LEDR(1)=wEn, LEDR(2)=effective_ready, LEDR(3)=ctrl_ready, LEDR(4)=debug_mode

entity top_dram_debug is
    port (
        CLOCK_50   : in    std_logic;
        KEY        : in    std_logic_vector(3 downto 0);
        SW         : in    std_logic_vector(9 downto 0);
        HEX0       : out   std_logic_vector(6 downto 0);
        HEX1       : out   std_logic_vector(6 downto 0);
        HEX2       : out   std_logic_vector(6 downto 0);
        HEX3       : out   std_logic_vector(6 downto 0);
        HEX4       : out   std_logic_vector(6 downto 0);
        HEX5       : out   std_logic_vector(6 downto 0);
        LEDR       : out   std_logic_vector(9 downto 0);
        DRAM_CLK   : out   std_logic;
        DRAM_CKE   : out   std_logic;
        DRAM_CS_N  : out   std_logic;
        DRAM_RAS_N : out   std_logic;
        DRAM_CAS_N : out   std_logic;
        DRAM_WE_N  : out   std_logic;
        DRAM_BA    : out   std_logic_vector(1 downto 0);
        DRAM_ADDR  : out   std_logic_vector(12 downto 0);
        DRAM_DQ    : inout std_logic_vector(15 downto 0);
        DRAM_UDQM  : out   std_logic;
        DRAM_LDQM  : out   std_logic
    );
end entity top_dram_debug;

architecture rtl of top_dram_debug is

    signal clk : std_logic;
    signal rst : std_logic;

    signal iface_address     : std_logic_vector(25 downto 0);
    signal iface_data_to_mem : std_logic_vector(7 downto 0);
    signal iface_req         : std_logic;
    signal iface_wEn         : std_logic;

    signal controller_ready    : std_logic;
    signal controller_data_out : std_logic_vector(7 downto 0);

    signal debug_mode      : std_logic;
    signal debug_ready     : std_logic;
    signal effective_ready : std_logic;

    signal iface_sw  : std_logic_vector(9 downto 0);
    signal iface_key : std_logic_vector(3 downto 0);

    signal ctrl_req : std_logic;
    signal ctrl_wEn : std_logic;

    signal iface_dbg_state : std_logic_vector(2 downto 0);

begin

    clk <= CLOCK_50;
    rst <= not KEY(0);  -- active-low KEY -> active-high reset

    debug_mode     <= not SW(9);           -- SW(9)=0 -> debug
    effective_ready <= '1' when debug_mode = '1' else controller_ready;

    -- Mask SW(9) for iface, invert KEY(3) (active-low on board)
    iface_sw  <= '0' & SW(8 downto 0);
    iface_key <= (not KEY(3)) & "000";

    -- Disable controller requests in debug mode
    ctrl_req <= '0' when debug_mode = '1' else iface_req;
    ctrl_wEn <= '0' when debug_mode = '1' else iface_wEn;

    u_iface: entity work.dram_iface
        port map (
            clk           => clk,
            rst           => rst,
            SW            => iface_sw,
            KEY           => iface_key,
            ready         => effective_ready,
            data_from_mem => controller_data_out,
            HEX0          => HEX0,
            HEX1          => HEX1,
            HEX4          => HEX4,
            HEX5          => HEX5,
            address       => iface_address,
            data_to_mem   => iface_data_to_mem,
            req           => iface_req,
            wEn           => iface_wEn,
            dbg_state     => iface_dbg_state
        );

    u_ctrl: entity work.dram_controller
        port map (
            clk        => clk,
            rst        => rst,
            address    => iface_address,
            data_in    => iface_data_to_mem,
            req        => ctrl_req,
            wEn        => ctrl_wEn,
            ready      => controller_ready,
            data_out   => controller_data_out,
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

    -- Debug LEDs
    LEDR(0) <= iface_req;
    LEDR(1) <= iface_wEn;
    LEDR(2) <= effective_ready;
    LEDR(3) <= controller_ready;
    LEDR(4) <= debug_mode;
    LEDR(5) <= ctrl_req;       -- req que chega ao controller
    LEDR(6) <= ctrl_wEn;       -- wEn que chega ao controller
    LEDR(9 downto 7) <= iface_dbg_state;  -- iface FSM: 000=READY, 010=WAIT_WR, 100=WAIT_RD

    -- HEX2/HEX3: show raw controller_data_out for debug
    hex2_inst: entity work.hex_decoder port map (value => controller_data_out(3 downto 0), hex => HEX2);
    hex3_inst: entity work.hex_decoder port map (value => controller_data_out(7 downto 4), hex => HEX3);

end architecture rtl;
