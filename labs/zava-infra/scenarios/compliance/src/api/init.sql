-- Initialize the application database
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Items')
BEGIN
    CREATE TABLE Items (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        Name NVARCHAR(255) NOT NULL,
        Description NVARCHAR(1000),
        CreatedAt DATETIME2 DEFAULT GETUTCDATE()
    );

    INSERT INTO Items (Name, Description) VALUES
        ('Sample Item 1', 'Created during initial deployment'),
        ('Sample Item 2', 'Another seed record');
END
