library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Модуль I2C Master (передача Tx та прийом Rx) для варіанта №29
entity i2c_master is
    Generic (
        INPUT_CLK_HZ : integer := 50_000_000; -- Вхідна тактова частота ПЛІС (50 МГц)
        BUS_CLK_HZ   : integer := 100_000     -- Частота шини I2C Standard Mode (100 кГц)
    );
    Port (
        clk       : in    STD_LOGIC;                    -- Системний тактовий сигнал
        reset_n   : in    STD_LOGIC;                    -- Асинхронне скидання (активний '0')
        ena       : in    STD_LOGIC;                    -- Сигнал запуску транзакції ('1')
        addr      : in    STD_LOGIC_VECTOR(6 downto 0); -- 7-бітна адреса Slave-пристрою
        rw        : in    STD_LOGIC;                    -- Режим: '0' = запис (Tx), '1' = читання (Rx)
        data_wr   : in    STD_LOGIC_VECTOR(7 downto 0); -- Байт даних для передачі (Tx)
        busy      : out   STD_LOGIC;                    -- Прапорець зайнятості шини ('1' - активна)
        data_rd   : out   STD_LOGIC_VECTOR(7 downto 0); -- Прийнятий байт даних (Rx)
        ack_error : out   STD_LOGIC;                    -- Помилка відсутності підтвердження (NACK)
        sda       : inout STD_LOGIC;                    -- Двонаправлена лінія даних I2C (Open-Drain)
        scl       : inout STD_LOGIC                     -- Тактова лінія I2C (Open-Drain)
    );
end i2c_master;

architecture Behavioral of i2c_master is
    -- Розрахунок дільника частоти для формування 4 фаз одного періоду SCL
    constant DIVIDER : integer := (INPUT_CLK_HZ / BUS_CLK_HZ) / 4;

    -- Стани скінченного автомата (FSM) протоколу I2C
    type state_type is (
        IDLE,       -- Очікування запуску транзакції
        START,      -- Формування умови START (спад SDA при високому SCL)
        ADDR_RW,    -- Передача 7 біт адреси та 1 біта напрямку R/W
        ACK_ADDR,   -- Очікування біта підтвердження ACK від Slave після адреси
        WRITE_DATA, -- Передача (Tx) 8 біт даних до Slave
        READ_DATA,  -- Прийом (Rx) 8 біт даних від Slave
        ACK_WRITE,  -- Очікування ACK від Slave після прийому байта
        MSTR_ACK,   -- Формування NACK від Master після завершення читання байта
        STOP        -- Формування умови STOP (фронт SDA при високому SCL)
    );
    signal state : state_type := IDLE;

    signal count         : integer range 0 to DIVIDER * 4 := 0;
    signal data_clk      : STD_LOGIC := '0'; -- Строб зміни даних (середина низького SCL)
    signal data_clk_prev : STD_LOGIC := '0';
    signal scl_clk       : STD_LOGIC := '0'; -- Внутрішній тактовий сигнал SCL
    signal scl_ena       : STD_LOGIC := '0'; -- Дозвіл видачі SCL на лінію
    signal sda_int       : STD_LOGIC := '1'; -- Внутрішній рівень SDA ('0' - притягнути до землі, '1' - відпустити)
    signal addr_rw_reg   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal data_tx_reg   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal data_rx_reg   : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal bit_cnt       : integer range 0 to 7 := 7;
    signal stretch       : STD_LOGIC := '0';
begin

    -- Генератор тактових фаз шини I2C (формування scl_clk та data_clk)
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            stretch <= '0';
            count   <= 0;
        elsif rising_edge(clk) then
            data_clk_prev <= data_clk;
            if count = DIVIDER * 4 - 1 then
                count <= 0;
            elsif stretch = '0' then
                count <= count + 1;
            end if;

            -- Формування 4 чвертей періоду SCL
            if count < DIVIDER then
                scl_clk  <= '0';
                data_clk <= '0';
            elsif count < DIVIDER * 2 then
                scl_clk  <= '0';
                data_clk <= '1';
            elsif count < DIVIDER * 3 then
                scl_clk  <= '1';
                if scl = '0' then -- Перевірка Clock Stretching від Slave
                    stretch <= '1';
                else
                    stretch <= '0';
                end if;
                data_clk <= '1';
            else
                scl_clk  <= '1';
                data_clk <= '0';
            end if;
        end if;
    end process;

    -- Основний скінченний автомат (FSM) керування передачею Tx та прийомом Rx
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            state       <= IDLE;
            busy        <= '1';
            scl_ena     <= '0';
            sda_int     <= '1';
            ack_error   <= '0';
            bit_cnt     <= 7;
            data_rd     <= (others => '0');
            data_rx_reg <= (others => '0');
        elsif rising_edge(clk) then
            -- Переходи станів та виставлення бітів на фронті data_clk
            if data_clk = '1' and data_clk_prev = '0' then
                case state is
                    when IDLE =>
                        if ena = '1' then
                            busy        <= '1';
                            addr_rw_reg <= addr & rw; -- Фіксуємо адресу та біт R/W
                            data_tx_reg <= data_wr;   -- Фіксуємо байт для передачі
                            state       <= START;
                        else
                            busy  <= '0';
                            state <= IDLE;
                        end if;

                    when START =>
                        busy    <= '1';
                        sda_int <= addr_rw_reg(bit_cnt); -- Виставляємо старший біт адреси
                        state   <= ADDR_RW;

                    when ADDR_RW =>
                        if bit_cnt = 0 then
                            sda_int <= '1'; -- Відпускаємо SDA для читання ACK від Slave
                            bit_cnt <= 7;
                            state   <= ACK_ADDR;
                        else
                            bit_cnt <= bit_cnt - 1;
                            sda_int <= addr_rw_reg(bit_cnt - 1);
                        end if;

                    when ACK_ADDR =>
                        if addr_rw_reg(0) = '0' then
                            -- Режим передачі (Tx): виставляємо 7-й біт даних
                            sda_int <= data_tx_reg(bit_cnt);
                            state   <= WRITE_DATA;
                        else
                            -- Режим прийому (Rx): тримаємо SDA у Z для читання від Slave
                            sda_int <= '1';
                            state   <= READ_DATA;
                        end if;

                    when WRITE_DATA =>
                        if bit_cnt = 0 then
                            sda_int <= '1'; -- Відпускаємо SDA для ACK після байта
                            bit_cnt <= 7;
                            state   <= ACK_WRITE;
                        else
                            bit_cnt <= bit_cnt - 1;
                            sda_int <= data_tx_reg(bit_cnt - 1);
                        end if;

                    when ACK_WRITE =>
                        if ena = '1' and addr_rw_reg = (addr & rw) and rw = '0' then
                            -- Безперервний запис наступного байта
                            data_tx_reg <= data_wr;
                            sda_int     <= data_wr(bit_cnt);
                            state       <= WRITE_DATA;
                        else
                            state <= STOP;
                        end if;

                    when READ_DATA =>
                        if bit_cnt = 0 then
                            -- Завершено прийом 8 біт: видаємо NACK ('1') для завершення читання
                            sda_int <= '1';
                            bit_cnt <= 7;
                            data_rd <= data_rx_reg;
                            state   <= MSTR_ACK;
                        else
                            bit_cnt <= bit_cnt - 1;
                        end if;

                    when MSTR_ACK =>
                        state <= STOP;

                    when STOP =>
                        busy  <= '0';
                        state <= IDLE;
                end case;

            -- Зчитування бітів зі шини SDA по центру високого імпульсу SCL (спад data_clk)
            elsif data_clk = '0' and data_clk_prev = '1' then
                case state is
                    when START =>
                        if scl_ena = '0' then
                            scl_ena   <= '1';
                            ack_error <= '0';
                        end if;

                    when ACK_ADDR =>
                        -- Перевіряємо ACK ('0' = успіх, '1' = помилка NACK)
                        if sda /= '0' then
                            ack_error <= '1';
                        end if;

                    when READ_DATA =>
                        -- Фіксуємо прийнятий біт від Slave у регістр зсуву
                        data_rx_reg(bit_cnt) <= sda;

                    when ACK_WRITE =>
                        if sda /= '0' then
                            ack_error <= '1';
                        end if;

                    when STOP =>
                        scl_ena <= '0'; -- Зупиняємо тактування SCL

                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- Формування умови START/STOP та буферів з відкритим стоком (Open-Drain: '0' або 'Z')
    scl <= '0' when (scl_ena = '1' and scl_clk = '0') else 'Z';
    sda <= '0' when (state = START and data_clk = '1') else
           '0' when (state = STOP  and data_clk = '0') else
           '0' when (sda_int = '0' and state /= START and state /= STOP) else
           'Z';

end Behavioral;