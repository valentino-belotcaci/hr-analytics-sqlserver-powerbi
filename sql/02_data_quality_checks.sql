USE [hr-data]
GO

/* =====================================================
   03_data_quality_checks.sql
   Goal: DETECT problems in the raw HR data.
   Nothing is modified: the raw tables stay as delivered.
   ===================================================== */


-- 1. Duplicate EmployeeIDs (same ID appears more than once).
SELECT EmployeeID, COUNT(*) as instances
FROM dbo.employees 
GROUP BY EmployeeID
HAVING COUNT(*) > 1

-- 2. Duplicate emails shared by DIFFERENT employees.
--    COUNT(DISTINCT EmployeeID) avoids counting the duplicated rows
--    of the same person as a problem.
SELECT Email, COUNT(DISTINCT EmployeeID) AS different_employees
FROM dbo.employees
GROUP BY Email
HAVING COUNT(DISTINCT EmployeeID) > 1;

-- 3. Missing department (DepartmentID is NULL).
SELECT EmployeeID
FROM dbo.employees 
WHERE DepartmentID IS NULL
ORDER BY EmployeeID

-- 4. Invalid department (ID filled in but not found in departments, e.g. 99)
SELECT EmployeeID, e.DepartmentID
FROM dbo.employees AS e
LEFT JOIN dbo.departments AS d
ON e.DepartmentID = d.DepartmentID
WHERE d.DepartmentID IS NULL
ORDER BY EmployeeID

-- 5. Employee who is their own manager.
SELECT EmployeeID 
FROM dbo.employees 
WHERE ManagerID = EmployeeID
ORDER BY EmployeeID

-- ManagerID that does not exist in employees.
SELECT e.EmployeeID 
FROM dbo.employees AS e
LEFT JOIN dbo.employees AS m
ON e.ManagerID = m.EmployeeID
WHERE m.EmployeeID IS NULL
ORDER BY e.EmployeeID

-- 7. Termination date before hire date.
SELECT EmployeeID, HireDate, TerminationDate
FROM dbo.employees
WHERE TerminationDate < HireDate
ORDER BY EmployeeID;
-- Expected: about 4 rows

-- 8. Hire date in the future.
SELECT EmployeeID, HireDate
FROM dbo.employees
WHERE HireDate > GETDATE()
ORDER BY EmployeeID;
-- Expected: about 3 rows (year 2028)

-- 9. Invalid salary: zero, negative, missing, or implausibly high.
--    The 500000 limit is my own rule: normal salaries here are far below it.
SELECT EmployeeID, Salary
FROM dbo.employees
WHERE Salary <= 0 OR Salary > 500000 OR Salary IS NULL
ORDER BY EmployeeID;
-- Expected: 3 rows (0, negative, 8,500,000)

-- 10. Invalid employment percentage.
--     Rule: valid range is 10-100 (my own assumption for part-time work).
SELECT EmployeeID, EmploymentPct
FROM dbo.employees
WHERE EmploymentPct > 100 OR EmploymentPct < 10 OR EmploymentPct IS NULL
ORDER BY EmployeeID;
-- Expected: 3 rows

-- 11. Employees under 18, using exact age (not calendar-year difference).
SELECT EmployeeID, BirthDate
FROM dbo.employees
WHERE BirthDate > DATEADD(year, -18, CAST(GETDATE() AS date))
ORDER BY EmployeeID;
-- Expected: 2 rows (born 2015)

-- 12. Missing names (blank or NULL).
SELECT EmployeeID, FirstName, LastName
FROM dbo.employees
WHERE FirstName IS NULL OR LTRIM(RTRIM(FirstName)) = ''
   OR LastName  IS NULL OR LTRIM(RTRIM(LastName))  = ''
ORDER BY EmployeeID;
-- Expected: 1 row (blank last name)

-- 13. Formatting problems in names:
--     (a) extra spaces at the start or end, (b) last name fully in capitals.
--     DATALENGTH compares the real length, because "=" ignores trailing spaces.
SELECT EmployeeID, FirstName, LastName
FROM dbo.employees
WHERE DATALENGTH(FirstName) <> DATALENGTH(LTRIM(RTRIM(FirstName)))
   OR DATALENGTH(LastName)  <> DATALENGTH(LTRIM(RTRIM(LastName)))
   OR LastName COLLATE Latin1_General_CS_AS = UPPER(LastName) COLLATE Latin1_General_CS_AS
ORDER BY EmployeeID;
-- Expected: 2 rows (extra spaces, capitals)

-- 14b. Gender values that are NOT exactly 'M' or 'F'
SELECT EmployeeID
FROM dbo.employees
WHERE Gender NOT LIKE 'M' AND Gender NOT LIKE 'F'

-- 15. Salary history rows whose employee does not exist (orphans).
SELECT sh.EmployeeID
FROM dbo.salary_history AS sh
LEFT JOIN dbo.employees AS e
    ON e.EmployeeID = sh.EmployeeID
WHERE e.EmployeeID IS NULL
ORDER BY sh.EmployeeID;
-- Expected: 2 rows (5555 and 6666)