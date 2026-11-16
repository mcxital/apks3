library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Testbench для верифікації I2C Master (Tx та Rx), варіант №29
entity i2c_master_tb is
end i2c_master_tb;

architecture Behavioral of i2c_master_tb is
    component i2c_master
        Generic (
            INPUT_CLK_HZ : integer := 50_000_000;
            BUS_CLK_HZ   : integer := 100_000
        );
        Port (
            clk       : in    STD_LOGIC;
            reset_n   : in    STD_LOGIC;
            ena       : in    STD_LOGIC;
            addr      : in    STD_LOGIC_VECTOR(6 downto 0);
            rw        : in    STD_LOGIC;
            data_wr   : in    STD_LOGIC_VECTOR(7 downto 0);
            busy      : out   STD_LOGIC;
            data_rd   : out   STD_LOGIC_VECTOR(7 downto 0);
            ack_error : out   STD_LOGIC;
            sda       : inout STD_LOGIC;
            scl       : inout STD_LOGIC
        );
    end component;

    constant CLK_PERIOD : time := 20 ns; -- 50 МГц

    signal clk       : STD_LOGIC := '0';
    signal reset_n   : STD_LOGIC := '0';
    signal ena       : STD_LOGIC := '0';
    signal addr      : STD_LOGIC_VECTOR(6 downto 0) := (others => '0');
    signal rw        : STD_LOGIC := '0';
    signal data_wr   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal busy      : STD_LOGIC;
    signal data_rd   : STD_LOGIC_VECTOR(7 downto 0);
    signal ack_error : STD_LOGIC;
    signal sda       : STD_LOGIC := 'Z';
    signal scl       : STD_LOGIC := 'Z';
    signal slave_sda : STD_LOGIC := 'Z';

begin
    -- Підтяжка ліній шини I2C до логічної '1' (Pull-Up)
    sda <= 'H';
    scl <= 'H';
    sda <= slave_sda;

    uut: i2c_master
        port map (
            clk       => clk,
            reset_n   => reset_n,
            ena       => ena,
            addr      => addr,
            rw        => rw,
            data_wr   => data_wr,
            busy      => busy,
            data_rd   => data_rd,
            ack_error => ack_error,
            sda       => sda,
            scl       => scl
        );

    -- Генерація тактового сигналу 50 МГц
    clk_process : process
    begin
        clk <= '0';
        wait for CLK_PERIOD / 2;
        clk <= '1';
        wait for CLK_PERIOD / 2;
    end process;

    -- Імітація роботи I2C Slave (формування ACK та передача байта 0x3C при читанні)
    slave_sim : process
        variable slave_tx_byte : STD_LOGIC_VECTOR(7 downto 0) := x"3C";
    begin
        slave_sda <= 'Z';
        -- Очікування умови START (спад SDA при високому SCL)
        wait until falling_edge(sda) and scl = '1';

        -- Пропускаємо 8 тактів адреси + R/W
        for i in 0 to 7 loop
            wait until falling_edge(scl);
        end loop;

        -- 9-й такт: Slave видає ACK ('0')
        slave_sda <= '0';
        wait until falling_edge(scl);
        slave_sda <= 'Z';

        -- Перевіряємо режим: якщо запис (Tx) — приймаємо байт і даємо ACK
        if rw = '0' then
            for i in 0 to 7 loop
                wait until falling_edge(scl);
            end loop;
            slave_sda <= '0'; -- ACK після прийому даних
            wait until falling_edge(scl);
            slave_sda <= 'Z';
        else
            -- Якщо читання (Rx) — видаємо байт 0x3C на шину SDA
            for i in 7 downto 0 loop
                if slave_tx_byte(i) = '0' then
                    slave_sda <= '0';
                else
                    slave_sda <= 'Z';
                end if;
                wait until falling_edge(scl);
            end loop;
            slave_sda <= 'Z'; -- Відпускаємо SDA для NACK від Master
        end if;
    end process;

    -- Основний сценарій тестування Tx та Rx
    stim_proc : process
    begin
        reset_n <= '0';
        wait for 100 ns;
        reset_n <= '1';
        wait for 200 ns;

        -- Тест 1: Передача (Tx) байта 0xA5 за адресою 0x50
        addr    <= "1010000"; -- 0x50
        rw      <= '0';       -- Запис (Tx)
        data_wr <= x"A5";
        ena     <= '1';
        wait until busy = '1';
        ena     <= '0';
        wait until busy = '0';

        wait for 20 us;

        -- Тест 2: Прийом (Rx) байта 0x3C за адресою 0x50
        addr    <= "1010000"; -- 0x50
        rw      <= '1';       -- Читання (Rx)
        ena     <= '1';
        wait until busy = '1';
        ena     <= '0';
        wait until busy = '0';

        wait for 20 us;
        assert false report "Simulation completed successfully" severity failure;
    end process;

end Behavioral;