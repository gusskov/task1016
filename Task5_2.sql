-- ============================================================================
-- ТАБЛИЦА СЫРЫХ ЛОГОВ (Хранение 30 дней)
-- ============================================================================
CREATE TABLE IF NOT EXISTS user_events (
    user_id UInt32,
    event_type String,
    points_spent UInt32,
    event_time DateTime
) ENGINE = MergeTree()
ORDER BY (event_time, user_id)
TTL event_time + INTERVAL 30 DAY DELETE;

-- ============================================================================
-- АГРЕГИРОВАННАЯ ТАБЛИЦА (Хранение 180 дней)
-- ============================================================================
CREATE TABLE IF NOT EXISTS user_events_aggregated (
    event_date Date,
    event_type String,
    -- подсчет уникальных пользователей
    unique_users AggregateFunction(uniq, UInt32),
    --подсчет суммы потраченных баллов
    total_spent AggregateFunction(sum, UInt32),
    -- подсчет количества действий
    total_actions AggregateFunction(count, UInt32)
) ENGINE = AggregatingMergeTree()
PRIMARY KEY (event_date, event_type)
ORDER BY (event_date, event_type)
TTL event_date + INTERVAL 180 DAY DELETE;

-- ============================================================================
-- МАТЕРИАЛИЗОВАННОЕ ПРЕДСТАВЛЕНИЕ 
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_user_events_aggregator
TO user_events_aggregated
AS SELECT
    toDate(event_time) AS event_date,
    event_type,
    uniqState(user_id) AS unique_users,
    sumState(points_spent) AS total_spent,
    countState(user_id) AS total_actions
FROM user_events
GROUP BY event_date, event_type;

INSERT INTO user_events VALUES
-- События 10 дней назад
(1, 'login', 0, now() - INTERVAL 10 DAY),
(2, 'signup', 0, now() - INTERVAL 10 DAY),
(3, 'login', 0, now() - INTERVAL 10 DAY),

-- События 7 дней назад
(1, 'login', 0, now() - INTERVAL 7 DAY),
(2, 'login', 0, now() - INTERVAL 7 DAY),
(3, 'purchase', 30, now() - INTERVAL 7 DAY),

-- События 5 дней назад
(1, 'purchase', 50, now() - INTERVAL 5 DAY),
(2, 'logout', 0, now() - INTERVAL 5 DAY),
(4, 'login', 0, now() - INTERVAL 5 DAY),

-- События 3 дня назад
(1, 'login', 0, now() - INTERVAL 3 DAY),
(3, 'purchase', 70, now() - INTERVAL 3 DAY),
(5, 'signup', 0, now() - INTERVAL 3 DAY),

-- События вчера
(2, 'purchase', 20, now() - INTERVAL 1 DAY),
(4, 'logout', 0, now() - INTERVAL 1 DAY),
(5, 'login', 0, now() - INTERVAL 1 DAY),

-- События сегодня
(1, 'purchase', 25, now()),
(2, 'login', 0, now()),
(3, 'logout', 0, now()),
(6, 'signup', 0, now()),
(6, 'purchase', 100, now());


SELECT * FROM user_events ;

SELECT event_date, event_type FROM user_events_aggregated;

-- ============================================================================
-- Retention: сколько пользователей вернулись в течение следующих 7 дней.
-- Формат результата - total_users_day_0|returned_in_7_days|retention_7d_percent|
-- ============================================================================


WITH user_days AS (
-- Список дней, в которые хаходили пользователи
    SELECT 
	    user_id, 
	    toDate(event_time) AS active_date,
	    event_type
    FROM user_events 
    GROUP BY user_id, active_date, event_type
)
SELECT distinct
    t1.active_date AS day_0,
    t1.user_id AS user_id
    --t2.active_date AS day_N
    --event_type
FROM user_days t1
LEFT JOIN user_days t2 ON t1.user_id = t2.user_id 
    AND t2.active_date > t1.active_date
    AND t2.active_date <= t1.active_date + 7
    --and t1.event_type = t2.event_type 
ORDER BY user_id, day_0;

-- ============================================================================
-- ИТОГОВЫЙ расчёт retention
-- ============================================================================
WITH user_days AS (
    SELECT 
        user_id, 
        toDate(event_time) AS active_date
    FROM user_events 
    GROUP BY user_id, active_date
), 
daily_retention AS (
    SELECT 
        t1.active_date AS day_0,
        count(DISTINCT t1.user_id) AS users_on_day,
        count(DISTINCT IF(t2.active_date > t1.active_date AND t2.active_date <= (t1.active_date + 7), t2.user_id, NULL)) AS returned
    FROM user_days t1
    LEFT JOIN user_days t2 ON t1.user_id = t2.user_id 
    GROUP BY day_0
)
SELECT 
    sum(users_on_day) AS total_users_day_0,
    sum(returned) AS returned_in_7_days,
    round((sum(returned) / sum(users_on_day)) * 100, 2) AS retention_7d_percent
FROM daily_retention;


-- ============================================================================
-- запрос с группировками по быстрой аналитике по дням
-- ============================================================================
SELECT
    event_date,
    event_type,
    uniqMerge(unique_users) AS unique_users,
    sumMerge(total_spent) AS total_spent,
    countMerge(total_actions) AS total_actions
FROM user_events_aggregated
GROUP BY event_date, event_type
ORDER BY event_date, event_type;



