-- ──────────────────────────────────────────────────────────────
--  Zava — Seed Database
--  Creates tables and inserts demo data for the SRE Agent lab
-- ──────────────────────────────────────────────────────────────

-- ── Products ────────────────────────────────────────────────

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Products')
BEGIN
    CREATE TABLE Products (
        Id          INT IDENTITY(1,1) PRIMARY KEY,
        Name        NVARCHAR(200)   NOT NULL,
        Price       DECIMAL(10,2)   NOT NULL,
        Category    NVARCHAR(100)   NOT NULL,
        CreatedAt   DATETIME2       DEFAULT GETUTCDATE()
    );
END;
GO

-- ── Orders ──────────────────────────────────────────────────

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Orders')
BEGIN
    CREATE TABLE Orders (
        Id              INT IDENTITY(1,1) PRIMARY KEY,
        CustomerName    NVARCHAR(200)   NOT NULL,
        CustomerEmail   NVARCHAR(200)   NOT NULL,
        OrderDate       DATETIME2       DEFAULT GETUTCDATE(),
        Status          NVARCHAR(50)    DEFAULT 'Pending',
        TotalAmount     DECIMAL(10,2)   NOT NULL
    );
END;
GO

-- ── OrderItems ──────────────────────────────────────────────

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'OrderItems')
BEGIN
    CREATE TABLE OrderItems (
        Id          INT IDENTITY(1,1) PRIMARY KEY,
        OrderId     INT             NOT NULL,
        ProductId   INT             NOT NULL,
        Quantity    INT             NOT NULL DEFAULT 1,
        UnitPrice   DECIMAL(10,2)   NOT NULL,
        CONSTRAINT FK_OrderItems_Orders   FOREIGN KEY (OrderId)   REFERENCES Orders(Id),
        CONSTRAINT FK_OrderItems_Products FOREIGN KEY (ProductId) REFERENCES Products(Id)
    );
END;
GO

-- ── Seed Products ───────────────────────────────────────────

IF NOT EXISTS (SELECT 1 FROM Products)
BEGIN
    INSERT INTO Products (Name, Price, Category) VALUES
    -- Espresso
    ('Zava Café Doppio Espresso',                3.50, 'Espresso'),
    ('Zava Café Cortado',                        4.25, 'Espresso'),
    ('Zava Café Americano',                      3.75, 'Espresso'),
    ('Zava Café Macchiato',                      4.00, 'Espresso'),
    ('Zava Café Ristretto',                      3.25, 'Espresso'),
    -- Brewed Coffee
    ('Zava Café Single-Origin Pour-Over',        5.50, 'Brewed Coffee'),
    ('Zava Café Cold Brew',                      5.00, 'Brewed Coffee'),
    ('Zava Café Nitro Cold Brew',                6.00, 'Brewed Coffee'),
    -- Pastries
    ('Zava Café Almond Croissant',               4.75, 'Pastries'),
    ('Zava Café Pain au Chocolat',               4.50, 'Pastries'),
    ('Zava Café Blueberry Scone',                3.95, 'Pastries'),
    ('Zava Café Lemon Loaf Slice',               4.25, 'Pastries'),
    ('Zava Café Cinnamon Roll',                  4.95, 'Pastries'),
    ('Zava Café Morning Bun',                    3.75, 'Pastries'),
    -- Merch
    ('Zava Café 12oz Ceramic Mug',              14.99, 'Merch'),
    ('Zava Café Reusable Tumbler',              22.50, 'Merch'),
    ('Zava Café Whole-Bean Bag (340g)',         18.00, 'Merch'),
    ('Zava Café Barista Apron',                 38.00, 'Merch'),
    ('Zava Café Pour-Over Filters (50ct)',       8.50, 'Merch'),
    ('Zava Café Espresso Tamper',               24.00, 'Merch');
END;
GO

-- ── Seed Orders ─────────────────────────────────────────────

IF NOT EXISTS (SELECT 1 FROM Orders)
BEGIN
    INSERT INTO Orders (CustomerName, CustomerEmail, OrderDate, Status, TotalAmount) VALUES
    ('Alice Johnson',   'alice@example.com',    '2025-01-15', 'Completed',   7.75),
    ('Bob Smith',       'bob@example.com',      '2025-01-18', 'Completed',   4.25),
    ('Carol Williams',  'carol@example.com',    '2025-02-01', 'Shipped',    16.95),
    ('David Brown',     'david@example.com',    '2025-02-10', 'Pending',     3.50),
    ('Eve Martinez',    'eve@example.com',      '2025-02-14', 'Completed',  46.25),
    ('Frank Lee',       'frank@example.com',    '2025-03-01', 'Shipped',    45.99),
    ('Grace Kim',       'grace@example.com',    '2025-03-05', 'Pending',     9.20),
    ('Hank Wilson',     'hank@example.com',     '2025-03-12', 'Completed',   4.00),
    ('Ivy Chen',        'ivy@example.com',      '2025-03-20', 'Shipped',    13.25),
    ('Jack Davis',      'jack@example.com',     '2025-04-01', 'Pending',    42.95);

    INSERT INTO OrderItems (OrderId, ProductId, Quantity, UnitPrice) VALUES
    (1, 1, 1,   3.50),  -- Alice: Doppio Espresso
    (1, 2, 1,   4.25),  -- Alice: Cortado
    (2, 2, 1,   4.25),  -- Bob: Cortado
    (3, 9, 2,   4.75),  -- Carol: 2x Almond Croissant
    (3, 11, 1,  3.95),  -- Carol: Blueberry Scone
    (3, 1, 1,   3.50),  -- Carol: Doppio Espresso
    (4, 1, 1,   3.50),  -- David: Doppio Espresso
    (5, 18, 1, 38.00),  -- Eve: Barista Apron
    (5, 10, 1,  4.50),  -- Eve: Pain au Chocolat
    (5, 14, 1,  3.75),  -- Eve: Morning Bun
    (6, 15, 1, 14.99),  -- Frank: Ceramic Mug
    (6, 16, 1, 22.50),  -- Frank: Reusable Tumbler
    (6, 19, 1,  8.50),  -- Frank: Pour-Over Filters
    (7, 2, 1,   4.25),  -- Grace: Cortado
    (7, 13, 1,  4.95),  -- Grace: Cinnamon Roll
    (8, 4, 1,   4.00),  -- Hank: Macchiato
    (9, 12, 2,  4.25),  -- Ivy: 2x Lemon Loaf Slice
    (9, 9, 1,   4.75),  -- Ivy: Almond Croissant
    (10, 18, 1, 38.00), -- Jack: Barista Apron
    (10, 13, 1,  4.95); -- Jack: Cinnamon Roll
END;
GO

-- ── Verify ──────────────────────────────────────────────────

SELECT 'Products' AS [Table], COUNT(*) AS [Rows] FROM Products
UNION ALL
SELECT 'Orders',     COUNT(*) FROM Orders
UNION ALL
SELECT 'OrderItems', COUNT(*) FROM OrderItems;
GO
