-- ================================================================
--  FLYWAY MIGRACIÓN V1 - Schema inicial
--  Ubicación: src/main/resources/db/migration/V1__schema_inicial.sql
--
--  H2 diferencias vs SQLite:
--   * BOOLEAN es tipo nativo (no INTEGER 0/1)
--   * CURRENT_TIMESTAMP funciona igual
--   * No soporta PRAGMA (no necesario, H2 maneja concurrencia solo)
--   * Los índices parciales (WHERE) no están soportados →
--     la unicidad de "una comanda viva por mesa" la reforzamos
--     en la capa Service de Java en su lugar.
-- ================================================================

-- ----------------------------------------------------------------
-- 1. EMPLEADOS
-- ----------------------------------------------------------------
CREATE TABLE empleados (
    id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    nombre      VARCHAR(100)  NOT NULL,
    rol         VARCHAR(20)   NOT NULL CHECK (rol IN ('MESERO','BARRA','COCINA','CAJA','ADMIN')),
    pin_hash    VARCHAR(255)  NOT NULL,
    activo      BOOLEAN       NOT NULL DEFAULT TRUE,
    creado_en   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------
-- 2. JORNADAS
-- ----------------------------------------------------------------
CREATE TABLE jornadas (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    apertura      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    cierre        TIMESTAMP,
    estado        VARCHAR(10)  NOT NULL DEFAULT 'ABIERTA'
                               CHECK (estado IN ('ABIERTA','CERRADA')),
    total_ventas  DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    abierta_por   BIGINT,
    cerrada_por   BIGINT,
    FOREIGN KEY (abierta_por) REFERENCES empleados(id),
    FOREIGN KEY (cerrada_por) REFERENCES empleados(id)
);

-- ----------------------------------------------------------------
-- 3. MESAS
-- ----------------------------------------------------------------
CREATE TABLE mesas (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    numero_mesa  VARCHAR(10)  NOT NULL UNIQUE,
    zona         VARCHAR(50),
    capacidad    INT          NOT NULL DEFAULT 4,
    estado       VARCHAR(15)  NOT NULL DEFAULT 'LIBRE'
                              CHECK (estado IN ('LIBRE','OCUPADA','POR_COBRAR')),
    activa       BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ----------------------------------------------------------------
-- 4. PRODUCTOS
-- ----------------------------------------------------------------
CREATE TABLE productos (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    nombre       VARCHAR(100)  NOT NULL,
    descripcion  VARCHAR(500),
    categoria    VARCHAR(50)   NOT NULL,
    destino      VARCHAR(10)   NOT NULL CHECK (destino IN ('BARRA','COCINA','DIRECTO')),
    precio       DECIMAL(8,2)  NOT NULL CHECK (precio >= 0),
    imagen_url   VARCHAR(500),
    receta       TEXT,
    disponible   BOOLEAN       NOT NULL DEFAULT TRUE,
    activo       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_productos_carta ON productos (activo, categoria);

-- ----------------------------------------------------------------
-- 5. MODIFICADORES
-- ----------------------------------------------------------------
CREATE TABLE modificadores (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    nombre        VARCHAR(100)  NOT NULL,
    grupo         VARCHAR(50),
    precio_extra  DECIMAL(8,2)  NOT NULL DEFAULT 0.00,
    activo        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE producto_modificador (
    producto_id     BIGINT NOT NULL,
    modificador_id  BIGINT NOT NULL,
    PRIMARY KEY (producto_id, modificador_id),
    FOREIGN KEY (producto_id)    REFERENCES productos(id)     ON DELETE CASCADE,
    FOREIGN KEY (modificador_id) REFERENCES modificadores(id) ON DELETE CASCADE
);

-- ----------------------------------------------------------------
-- 6. COMANDAS
-- ----------------------------------------------------------------
CREATE TABLE comandas (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    mesa_id         BIGINT        NOT NULL,
    jornada_id      BIGINT        NOT NULL,
    mesero_id       BIGINT        NOT NULL,
    estado          VARCHAR(15)   NOT NULL DEFAULT 'ABIERTA'
                                  CHECK (estado IN ('ABIERTA','POR_COBRAR','PAGADA','ANULADA')),
    total           DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    fecha_apertura  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_cierre    TIMESTAMP,
    FOREIGN KEY (mesa_id)    REFERENCES mesas(id),
    FOREIGN KEY (jornada_id) REFERENCES jornadas(id),
    FOREIGN KEY (mesero_id)  REFERENCES empleados(id)
);

CREATE INDEX idx_comandas_jornada ON comandas (jornada_id, estado);
CREATE INDEX idx_comandas_mesa    ON comandas (mesa_id, estado);

-- ----------------------------------------------------------------
-- 7. SUBCUENTAS
-- ----------------------------------------------------------------
CREATE TABLE subcuentas (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    comanda_id   BIGINT        NOT NULL,
    nombre       VARCHAR(100)  NOT NULL,
    total        DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    estado       VARCHAR(15)   NOT NULL DEFAULT 'PENDIENTE'
                               CHECK (estado IN ('PENDIENTE','PAGADA')),
    metodo_pago  VARCHAR(20)   CHECK (metodo_pago IN ('EFECTIVO','TARJETA','TRANSFERENCIA')),
    fecha_pago   TIMESTAMP,
    FOREIGN KEY (comanda_id) REFERENCES comandas(id) ON DELETE CASCADE
);

CREATE INDEX idx_subcuentas_comanda ON subcuentas (comanda_id);

-- ----------------------------------------------------------------
-- 8. DETALLE_COMANDA
-- ----------------------------------------------------------------
CREATE TABLE detalle_comanda (
    id                   BIGINT AUTO_INCREMENT PRIMARY KEY,
    comanda_id           BIGINT        NOT NULL,
    subcuenta_id         BIGINT,
    producto_id          BIGINT        NOT NULL,
    nombre_producto      VARCHAR(100)  NOT NULL,
    precio_unitario      DECIMAL(8,2)  NOT NULL,
    precio_modificadores DECIMAL(8,2)  NOT NULL DEFAULT 0.00,
    notas                VARCHAR(500),
    destino              VARCHAR(10)   NOT NULL CHECK (destino IN ('BARRA','COCINA','DIRECTO')),
    estado_preparacion   VARCHAR(15)   NOT NULL DEFAULT 'PENDIENTE'
                                       CHECK (estado_preparacion IN
                                             ('PENDIENTE','EN_PROCESO','LISTO','ENTREGADO','CANCELADO')),
    entregado_por_mesero BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_solicitud      TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_inicio_prep    TIMESTAMP,
    fecha_listo          TIMESTAMP,
    creado_por           BIGINT        NOT NULL,
    -- Idempotencia: UUID generado en el cliente para evitar duplicados
    uuid_cliente         VARCHAR(36)   NOT NULL UNIQUE,
    -- Bloqueo optimista: @Version en JPA usa esta columna
    version              INT           NOT NULL DEFAULT 0,
    FOREIGN KEY (comanda_id)   REFERENCES comandas(id)    ON DELETE CASCADE,
    FOREIGN KEY (subcuenta_id) REFERENCES subcuentas(id)  ON DELETE SET NULL,
    FOREIGN KEY (producto_id)  REFERENCES productos(id),
    FOREIGN KEY (creado_por)   REFERENCES empleados(id)
);

CREATE INDEX idx_cola_fifo       ON detalle_comanda (destino, estado_preparacion, fecha_solicitud);
CREATE INDEX idx_detalle_comanda ON detalle_comanda (comanda_id);

CREATE TABLE detalle_modificador (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    detalle_id      BIGINT        NOT NULL,
    modificador_id  BIGINT        NOT NULL,
    nombre_snapshot VARCHAR(100)  NOT NULL,
    precio_aplicado DECIMAL(8,2)  NOT NULL DEFAULT 0.00,
    FOREIGN KEY (detalle_id)     REFERENCES detalle_comanda(id) ON DELETE CASCADE,
    FOREIGN KEY (modificador_id) REFERENCES modificadores(id)
);

-- ----------------------------------------------------------------
-- 9. FACTURAS
-- ----------------------------------------------------------------
CREATE TABLE facturas (
    id             BIGINT AUTO_INCREMENT PRIMARY KEY,
    subcuenta_id   BIGINT        NOT NULL UNIQUE,
    jornada_id     BIGINT        NOT NULL,
    cliente_nombre VARCHAR(200)  NOT NULL,
    tipo_id        VARCHAR(20)   NOT NULL CHECK (tipo_id IN ('CEDULA','RUC','PASAPORTE')),
    identificacion VARCHAR(20)   NOT NULL,
    correo         VARCHAR(200)  NOT NULL,
    monto_total    DECIMAL(10,2) NOT NULL,
    fecha_emision  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (subcuenta_id) REFERENCES subcuentas(id),
    FOREIGN KEY (jornada_id)   REFERENCES jornadas(id)
);

-- ----------------------------------------------------------------
-- 10. EVENTOS_AUDITORIA
-- ----------------------------------------------------------------
CREATE TABLE eventos_auditoria (
    id             BIGINT AUTO_INCREMENT PRIMARY KEY,
    jornada_id     BIGINT,
    empleado_id    BIGINT,
    autorizado_por BIGINT,
    tipo_evento    VARCHAR(50)   NOT NULL,
    entidad        VARCHAR(50)   NOT NULL,
    entidad_id     BIGINT,
    detalle        VARCHAR(1000),
    fecha          TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (jornada_id)     REFERENCES jornadas(id),
    FOREIGN KEY (empleado_id)    REFERENCES empleados(id),
    FOREIGN KEY (autorizado_por) REFERENCES empleados(id)
);

CREATE INDEX idx_auditoria_jornada ON eventos_auditoria (jornada_id, fecha);

-- ----------------------------------------------------------------
-- DATOS SEMILLA
-- ----------------------------------------------------------------
INSERT INTO mesas (numero_mesa, zona, capacidad) VALUES
    ('1', 'ESCENARIO', 4),
    ('2', 'ESCENARIO', 4),
    ('3', 'CENTRO', 6),
    ('4', 'BARRA', 2),
    ('5', 'CENTRO', 4),
    ('6', 'TERRAZA', 4);

INSERT INTO productos (nombre, categoria, destino, precio, disponible) VALUES
    ('Old Fashioned',    'COCTELES',  'BARRA',   9.50,  TRUE),
    ('Mojito',           'COCTELES',  'BARRA',   8.00,  TRUE),
    ('Negroni',          'COCTELES',  'BARRA',  10.00,  TRUE),
    ('Cerveza Pilsener', 'CERVEZAS',  'DIRECTO', 3.50,  TRUE),
    ('Agua sin gas',     'BEBIDAS',   'DIRECTO', 1.50,  TRUE),
    ('Agua con gas',     'BEBIDAS',   'DIRECTO', 1.50,  TRUE),
    ('Tabla de quesos',  'PICADAS',   'COCINA', 12.00,  TRUE),
    ('Alitas BBQ',       'PICADAS',   'COCINA',  9.00,  TRUE);

INSERT INTO modificadores (nombre, grupo, precio_extra) VALUES
    ('Sin hielo',    'HIELO',  0.00),
    ('Extra hielo',  'HIELO',  0.00),
    ('Shot extra',   'EXTRAS', 3.00),
    ('Sin azúcar',   'EXTRAS', 0.00);

INSERT INTO producto_modificador (producto_id, modificador_id) VALUES
    (1, 1), (1, 2), (1, 3),
    (2, 1), (2, 2), (2, 4),
    (3, 1), (3, 2), (3, 3);

-- Empleado admin inicial (PIN: 1234 → hash BCrypt de ejemplo)
-- En Fase 3 generarás hashes reales con BCryptPasswordEncoder
INSERT INTO empleados (nombre, rol, pin_hash) VALUES
    ('Admin', 'ADMIN', '$2a$10$exemplo.hash.que.reemplazaras.en.fase3');
