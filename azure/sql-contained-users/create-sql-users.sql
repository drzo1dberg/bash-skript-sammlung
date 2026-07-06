-- appdb Post-Apply: contained DB-User fuer die FE/BE User-Assigned Managed Identities.
-- Auszufuehren auf DB [appdb] als Mitglied von sql-admins-group.
--
-- Idempotent: CREATE USER ist gegen Doppelanlage geschuetzt (IF NOT EXISTS),
-- ALTER ROLE ... ADD MEMBER ist von Natur aus idempotent (kein Fehler, wenn das
-- Principal bereits Mitglied ist). Das Skript kann also gefahrlos wiederholt werden.
--
-- Wann erneut noetig? Diese User leben IN der DB und ueberleben jedes
-- `terraform apply`. Re-Run nur, wenn die DB neu/restored wird oder eine MI
-- neu erstellt wird (neue principalId -> alter contained user verwaist).
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'app-fe-mi')
    CREATE USER [app-fe-mi] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [app-fe-mi];
ALTER ROLE db_datawriter ADD MEMBER [app-fe-mi];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'app-be-mi')
    CREATE USER [app-be-mi] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [app-be-mi];
ALTER ROLE db_datawriter ADD MEMBER [app-be-mi];
GO

-- Verifikation: Rollen-Mitgliedschaften der beiden MIs ausgeben.
SELECT dp.name AS [user], r.name AS [role]
FROM sys.database_role_members drm
JOIN sys.database_principals r  ON r.principal_id  = drm.role_principal_id
JOIN sys.database_principals dp ON dp.principal_id = drm.member_principal_id
WHERE dp.name IN (N'app-fe-mi', N'app-be-mi')
ORDER BY dp.name, r.name;
GO
