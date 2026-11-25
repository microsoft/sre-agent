-- =============================================================================
-- Caldova Expense — Idempotent SQL Server Schema, Stored Proc & Integrated Auth
-- Target: SQL Server 2022 Express / Developer Edition (CaldovaExpenseDb)
-- =============================================================================
SET NOCOUNT ON;

IF DB_ID(N'CaldovaExpenseDb') IS NULL
BEGIN
    PRINT 'Creating database [CaldovaExpenseDb]...';
    CREATE DATABASE [CaldovaExpenseDb];
END
GO

USE [CaldovaExpenseDb];
GO

IF OBJECT_ID(N'dbo.ExpenseReports', N'U') IS NULL
BEGIN
    PRINT 'Creating table [dbo].[ExpenseReports]...';
    CREATE TABLE dbo.ExpenseReports
    (
        Id              INT IDENTITY(1001, 1) NOT NULL CONSTRAINT PK_ExpenseReports PRIMARY KEY CLUSTERED,
        EmployeeName    NVARCHAR(120)         NOT NULL,
        EmployeeEmail   NVARCHAR(160)         NOT NULL,
        Department      NVARCHAR(80)          NOT NULL,
        Category        NVARCHAR(80)          NOT NULL,
        Amount          DECIMAL(12, 2)        NOT NULL,
        Status          NVARCHAR(40)          NOT NULL CONSTRAINT DF_ExpenseReports_Status DEFAULT (N'Submitted'),
        SapVoucherId    NVARCHAR(50)          NULL,
        Description     NVARCHAR(400)         NULL,
        SubmittedAtUtc  DATETIME2(0)          NOT NULL CONSTRAINT DF_ExpenseReports_SubmittedAtUtc DEFAULT (SYSUTCDATETIME())
    );

    CREATE INDEX IX_ExpenseReports_SubmittedAtUtc ON dbo.ExpenseReports (SubmittedAtUtc DESC);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_SubmitExpenseReport
    @EmployeeName   NVARCHAR(120),
    @EmployeeEmail  NVARCHAR(160),
    @Department     NVARCHAR(80),
    @Category       NVARCHAR(80),
    @Amount         DECIMAL(12, 2),
    @Status         NVARCHAR(40) = N'Submitted',
    @SapVoucherId   NVARCHAR(50) = NULL,
    @Description    NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.ExpenseReports
        (EmployeeName, EmployeeEmail, Department, Category, Amount, Status, SapVoucherId, Description, SubmittedAtUtc)
    VALUES
        (@EmployeeName, @EmployeeEmail, @Department, @Category, @Amount, @Status, @SapVoucherId, @Description, SYSUTCDATETIME());

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS NewExpenseId;
END
GO

IF NOT EXISTS (SELECT 1 FROM dbo.ExpenseReports)
BEGIN
    PRINT 'Seeding baseline Caldova expense reports...';
    INSERT INTO dbo.ExpenseReports (EmployeeName, EmployeeEmail, Department, Category, Amount, Status, SapVoucherId, Description, SubmittedAtUtc)
    VALUES
        (N'Elena Rostova',   N'erostova@caldovagroup.com',  N'Plant Operations',   N'Safety Equipment',       320.50, N'Submitted',         NULL,                  N'Arc-flash PPE replacement kit',                 DATEADD(HOUR, -18, SYSUTCDATETIME())),
        (N'Marcus Vance',    N'mvance@caldovagroup.com',    N'Supply Chain',       N'Vendor Site Audit',     1180.00, N'ApprovedAndPosted', N'SAPFI-20261122-01002', N'Midwest logistics warehouse audit travel',      DATEADD(HOUR, -12, SYSUTCDATETIME())),
        (N'Priya Nair',      N'pnair@caldovagroup.com',     N'IT Infrastructure',  N'Hardware Spares',        475.00, N'Submitted',         NULL,                  N'SFP+ transceivers for East US 2 VPN edge',      DATEADD(HOUR, -6,  SYSUTCDATETIME())),
        (N'Jordan Rivera',   N'jrivera@caldovagroup.com',   N'Field Engineering',  N'Customer Onsite Travel', 640.00, N'PostedToSapFi',     N'SAPFI-20261123-01004', N'Regional substation inspection travel/lodging', DATEADD(HOUR, -2,  SYSUTCDATETIME()));
END
GO

-- Grant Windows Integrated Auth to IIS AppPool virtual account (only if running on Windows with IIS AppPool created)
DECLARE @AppPoolLogin NVARCHAR(128) = N'IIS APPPOOL\CaldovaExpensePool';
BEGIN TRY
    IF SUSER_ID(@AppPoolLogin) IS NULL
    BEGIN
        DECLARE @CreateLoginSql NVARCHAR(400) = N'CREATE LOGIN ' + QUOTENAME(@AppPoolLogin) + N' FROM WINDOWS;';
        EXEC sp_executesql @CreateLoginSql;
        PRINT 'Created SQL Server login for [IIS APPPOOL\CaldovaExpensePool].';
    END

    IF DATABASE_PRINCIPAL_ID(@AppPoolLogin) IS NULL
    BEGIN
        DECLARE @CreateUserSql NVARCHAR(400) = N'CREATE USER ' + QUOTENAME(@AppPoolLogin) + N' FOR LOGIN ' + QUOTENAME(@AppPoolLogin) + N';';
        EXEC sp_executesql @CreateUserSql;
    END

    EXEC sp_addrolemember N'db_datareader', @AppPoolLogin;
    EXEC sp_addrolemember N'db_datawriter', @AppPoolLogin;

    DECLARE @GrantExecSql NVARCHAR(400) = N'GRANT EXECUTE TO ' + QUOTENAME(@AppPoolLogin) + N';';
    EXEC sp_executesql @GrantExecSql;
    PRINT 'Granted db_datareader, db_datawriter, and EXECUTE on CaldovaExpenseDb to [IIS APPPOOL\CaldovaExpensePool].';
END TRY
BEGIN CATCH
    PRINT 'Note: Could not map [IIS APPPOOL\CaldovaExpensePool] yet (' + ERROR_MESSAGE() + '). Ensure IIS AppPool is created first, then re-run 2-setup-database.ps1.';
END CATCH
GO
