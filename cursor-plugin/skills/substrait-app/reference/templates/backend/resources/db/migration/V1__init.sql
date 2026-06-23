-- Flyway migration (OceanBase / MySQL dialect). All DDL lives here, never in code.
-- Delete this sample and add your own schema.

CREATE TABLE items (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    name        VARCHAR(255) NOT NULL,
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) DEFAULT CHARSET=utf8mb4;
